--[[
 Copyright (c) 2016-present, Facebook, Inc.
 All rights reserved.

 This source code is licensed under the license found in the
 LICENSE-examples file in the root directory of this source tree.
--]]
require('nn')
require('paths')

local tnt = require('torchnet')

-- use GPU or not:
local cmd = torch.CmdLine()
cmd:option('-usegpu', false, 'use gpu for training')
cmd:option('-seed', 1111, 'use gpu for training')

local config = cmd:parse(arg)
print(string.format('running on %s', config.usegpu and 'GPU' or 'CPU'))

local mpi = require('torchmpi')
-- The model we use for GPU + MPI is 1 Lua/Terra process for 1 GPU
-- mpi.start sets the GPU automatically
mpi.start(config.usegpu)
local mpinn = require('torchmpi.nn')
local cache = require('torchmpi.cache')
local parameterserver = require('torchmpi.parameterserver')

-- Set the random seed manually for reproducibility.
torch.manualSeed(config.seed)

-- set up logistic regressor:
local net = nn.Sequential():add(nn.Linear(784,10))
-- Perform weight and bias synchronization before starting training
mpinn.synchronizeParameters(net)
for _, v in pairs(net:parameters()) do mpi.checkWithAllreduce(v, 'initialParameters') end
local criterion = nn.CrossEntropyCriterion()

-- set up training engine:
local engine = tnt.SGDEngine()
local meter  = tnt.AverageValueMeter()
local clerr  = tnt.ClassErrorMeter{topk = {1}}
engine.hooks.onStartEpoch = function(state)
   meter:reset()
   clerr:reset()
end

local correctnessCheck = true
engine.hooks.onForwardCriterion = function(state)
   if correctnessCheck then mpinn.checkWithAllreduce(state.network) end
   meter:add(state.criterion.output)
   clerr:add(state.network.output, state.sample.target)
   if state.training then
      print(string.format('[%d/%d] avg. loss: %2.4f; avg. error: %2.4f',
         mpi.rank() + 1, mpi.size(), meter:value(), clerr:value{k = 1}))
   end
end

-- Synchronize gradients, this involves a few synchronous steps and barriers.
-- This is expected to be quite slower than allreduce so prefer using allreduce
-- if applicable but it is a working test and proof of concept.
local function synchronizeGradientsWithParameterServer(net)
   local w, gw = net:parameters()
   for _, t in pairs(gw) do
      -- Clone your tensor if needed,
      -- parameterserver.init will immediately retain and use its storage.
      cache.parameterServers[t] =
         cache.parameterServers[t] or parameterserver.init(t)

      if mpi.rank() == 0 then
         parameterserver.syncHandle(parameterserver.send(cache.parameterServers[t], t, 'zero'))
      end
      -- The combination of the syncHandle above and the mpi.barrier() call
      -- guarantees that everyone finished its update rule
      mpi.barrier()

      parameterserver.syncHandle(parameterserver.send(cache.parameterServers[t], t, 'add'))
      -- The combination of the syncHandle above and the mpi.barrier() call
      -- guarantees that everyone finished its update rule
      mpi.barrier()

      parameterserver.syncHandle(parameterserver.receive(cache.parameterServers[t], t))
      -- This barrier should be unnecessary (because only local parameterserver.syncHandle is needed)
      -- mpi.barrier()

      t:div(mpi.size())
   end
end

engine.hooks.onBackward = function(state)
   -- Note you can always do getParameters and use that to synchronize
   local p, g = net:parameters()
   synchronizeGradientsWithParameterServer(state.network)
end

-- set up GPU training:
if config.usegpu then
   cutorch.manualSeed(config.seed)

   -- copy model to GPU:
   require('cunn')
   net       = net:cuda()
   criterion = criterion:cuda()

   -- copy sample to GPU buffer:
   local igpu, tgpu = torch.CudaTensor(), torch.CudaTensor()
   engine.hooks.onSample = function(state)
      igpu:resize(state.sample.input:size() ):copy(state.sample.input)
      tgpu:resize(state.sample.target:size()):copy(state.sample.target)
      state.sample.input  = igpu
      state.sample.target = tgpu
   end  -- alternatively, this logic can be implemented via a TransformDataset
end

local makeIterator = paths.dofile('makeiterator.lua')

-- train the model:
engine:train{
   network   = net,
   iterator  = makeIterator('train'),
   criterion = criterion,
   lr        = 0.2,
   maxepoch  = 5,
}

-- measure test loss and error:
meter:reset()
clerr:reset()
engine:test{
   network   = net,
   iterator  = makeIterator('test'),
   criterion = criterion,
}

-- Sanity check, paramMean for all processes should be the same, this may diverge
-- a bit in the absence of double precision
for _, v in pairs(net:parameters()) do mpi.checkWithAllreduce(v, 'final parameters') end

local loss = meter:value()
local err = clerr:value{k = 1}
print(string.format('[%d/%d] test loss: %2.4f; test error: %2.4f',
   mpi.rank() + 1, mpi.size(), loss, err))

mpi.checkWithAllreduce(loss, 'final loss')

mpi.stop()
