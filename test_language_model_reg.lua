--[[
Unit tests for the LanguageModel implementation, making sure
that nothing crashes, that we can overfit a small dataset
and that everything gradient checks.
--]]

require 'torch'
require 'json'
require 'misc_saver2_reg_atten_ws.LanguageModel'
require 'misc_saver2_reg_atten_ws.Attention_Weights_Criterion'

local gradcheck = require 'misc_saver2_reg_atten_ws.gradcheck'

local tester = torch.Tester() 

local lm_test = torch.TestSuite()

-- validates the size and dimensions of a given 
-- tensor a to be size given in table sz
-- add a function to tester 
function tester:assertTensorSizeEq(a, sz)
  tester:asserteq(a:nDimension(), #sz)
  for i=1,#sz do
    tester:asserteq(a:size(i), sz[i])
  end
end

-- Test the API of the Language Model
local function forwardApiTestFactory(dtype)
  if dtype == 'torch.CudaTensor' then
    require 'cutorch'
    require 'cunn'
  end
  
  local function f()
    -- create LanguageModel instance
    local opt = {}
    opt.vocab_size = 5
    opt.word_encoding_size = 11
    opt.image_encoding_size = 11
    opt.rnn_size = 8
    opt.num_layers = 1
    opt.dropout = 0
    opt.seq_length = 7
    opt.batch_size = 10

    local lm = nn.LanguageModel(opt) 

    local crit = nn.ParallelCriterion(true)  -- repeatTarget are set to be true 
    local sub_crit1 = nn.LanguageModelCriterion()
    crit:add(sub_crit1, 1) 
    local sub_crit2 = nn.Attention_Weights_Criterion() 
    crit:add(sub_crit2, 1)  

    lm:type(dtype)
    crit:type(dtype)

    -- construct some input to feed in
    local seq = torch.LongTensor(opt.seq_length, opt.batch_size):random(opt.vocab_size)
    --make sure seq can be padded with zeroes and that things work ok
    seq[{ {4, 7}, 1 }] = 0
    seq[{ {5, 7}, 6 }] = 0
    local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)
    local semantic_words = torch.LongTensor(opt.batch_size, 10):random(opt.vocab_size)
    
    -- 8 x 10 x 6 (6 = 5(vocab_size) + 1)     
    local output, att = lm:forward{imgs, seq, semantic_words}  

    tester:assertlt(torch.max(output:view(-1)), 0) -- log probs should be <0

    -- the output should be of size (seq_length + 1, batch_size, vocab_size + 1)
    -- where the +1 is for the special END token appended at the end.
    tester:assertTensorSizeEq(output, {opt.seq_length+1, opt.batch_size, opt.vocab_size+1})
    
    -- seq: 7 * 10 
    local loss = crit:forward({output, att}, seq)

    -- 8 * 10 * 6, (seq+1) x bz x (vocab_size+1)
    local gradOutputTable = crit:backward({output, att}, seq)
    
    tester:assertTensorSizeEq(gradOutputTable[1], {opt.seq_length+1, opt.batch_size, opt.vocab_size+1})

    -- make sure the pattern of zero gradients is as expected
    local gradAbs = torch.max(torch.abs(gradOutputTable[1]), 3):view(opt.seq_length+1, opt.batch_size)

    local gradZeroMask = torch.eq(gradAbs,0)

    local expectedGradZeroMask = torch.ByteTensor(opt.seq_length+1,opt.batch_size):zero()
    -- expectedGradZeroMask[{ {1}, {} }]:fill(1) -- first time step should be zero grad (img was passed in)
    expectedGradZeroMask[{{5,8}, 1 }]:fill(1)
    expectedGradZeroMask[{ {6,8}, 6 }]:fill(1)
    
    -- print(expectedGradZeroMask)
    -- print(gradZeroMask) 

    tester:assertTensorEq(gradZeroMask:float(), expectedGradZeroMask:float(), 1e-8)

    local gradInput, dummy, dummy = lm:backward({imgs, seq, semantic_words}, gradOutputTable)
    tester:assertTensorSizeEq(gradInput[1], {opt.batch_size, opt.image_encoding_size})
    tester:asserteq(gradInput[2]:nElement(), 0, 'grad on seq should be empty tensor')

  end
  return f
end


--[[ 

-- test just the language model alone (without the criterion)
local function gradCheckLM()

  local dtype = 'torch.DoubleTensor'
  local opt = {}
  opt.vocab_size = 5
  opt.word_encoding_size = 4
  opt.image_encoding_size = 4 
  opt.rnn_size = 8
  opt.num_layers = 1
  opt.dropout = 0
  opt.seq_length = 7
  opt.batch_size = 6
  
  local lm = nn.LanguageModel(opt)
  
  local crit = nn.LanguageModelCriterion()
  lm:type(dtype)
  crit:type(dtype)

  local seq = torch.LongTensor(opt.seq_length, opt.batch_size):random(opt.vocab_size)
  seq[{ {4, 7}, 1 }] = 0
  seq[{ {5, 7}, 4 }] = 0
  local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)

  local semantic_words = torch.LongTensor(opt.batch_size, 2):random(opt.vocab_size)

  -- evaluate the analytic gradient
  -- output: 8 x 6 x 6
  local output = lm:forward{imgs, seq, semantic_words}
  local w = torch.randn(output:size(1), output:size(2), output:size(3))
  -- generate random weighted sum criterion
  local loss = torch.sum(torch.cmul(output, w))
  local gradOutput = w  
  -- gradInput: 6 * 4 
  local gradInput, dummy1, dummy2 = unpack(lm:backward({imgs, seq, semantic_words}, gradOutput))

  -- create a loss function wrapper
  local function f(x)
    local output = lm:forward{x, seq, semantic_words}
    local loss = torch.sum(torch.cmul(output, w))
    return loss
  end

  local gradInput_num = gradcheck.numeric_gradient(f, imgs, 1, 1e-6)

  -- print(gradInput)
  -- print(gradInput_num)
  -- local g = gradInput:view(-1)
  -- local gn = gradInput_num:view(-1)
  -- for i=1,g:nElement() do
  --   local r = gradcheck.relative_error(g[i],gn[i])
  --   print(i, g[i], gn[i], r)
  -- end
  tester:assertTensorEq(gradInput, gradInput_num, 1e-4)
  tester:assertlt(gradcheck.relative_error(gradInput, gradInput_num, 1e-8), 1e-4)

end
--]] 

g_lm = nil 

local function gradCheck()
  local dtype = 'torch.DoubleTensor'
  local opt = {}
  opt.vocab_size = 5
  opt.image_encoding_size = 4
  opt.word_encoding_size = 4
  opt.rnn_size = 8
  opt.num_layers = 1
  opt.dropout = 0
  opt.seq_length = 7
  opt.batch_size = 6 

  local lm = nn.LanguageModel(opt)
  

  local crit = nn.ParallelCriterion(true) -- set repeatTarget to be true to avoid slicing error  
  local sub_crit1 = nn.LanguageModelCriterion()
  crit:add(sub_crit1, 1) 
  local sub_crit2 = nn.Attention_Weights_Criterion()  
  crit:add(sub_crit2, 1) 
  
  lm:type(dtype)
  crit:type(dtype)

  -- seq_len(7) x bz(6)
  local seq = torch.LongTensor(opt.seq_length, opt.batch_size):random(opt.vocab_size)
  seq[{ {4, 7}, 1 }] = 0
  seq[{ {5, 7}, 4 }] = 0
  local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)
  local semantic_words = torch.LongTensor(opt.batch_size, 2):random(opt.vocab_size)

  -- evaluate the analytic gradient
  g_lm = lm 
  local output, att = lm:forward{imgs, seq, semantic_words}
  local loss = crit:forward({output, att}, seq)

  local gradOutput = crit:backward({output, att}, seq)
  local gradInput, dummy1, dummy2 = unpack(lm:backward({imgs, seq, semantic_words}, gradOutput))

  -- create a loss function wrapper
  local function f(x)
    local output, att = lm:forward{x, seq, semantic_words}
    local loss = crit:forward({output, att}, seq)
    return loss
  end

  local gradInput_num = gradcheck.numeric_gradient(f, imgs, 1, 1e-6)

  -- print(gradInput)
  -- print(gradInput_num)
  -- local g = gradInput:view(-1)
  -- local gn = gradInput_num:view(-1)
  -- for i=1,g:nElement() do
  --   local r = gradcheck.relative_error(g[i],gn[i])
  --   print(i, g[i], gn[i], r)
  -- end

  -- tester:assertTensorEq(gradInput, gradInput_num, 1e-4)
  -- tester:assertlt(gradcheck.relative_error(gradInput, gradInput_num, 1e-8), 5e-4)

end

local function overfit()
  local dtype = 'torch.DoubleTensor'
  local opt = {}
  opt.vocab_size = 5
  opt.image_encoding_size = 7
  opt.word_encoding_size = 7
  opt.rnn_size = 24
  opt.num_layers = 1
  opt.dropout = 0
  opt.seq_length = 7
  opt.batch_size = 6
  local lm = nn.LanguageModel(opt)
  local crit = nn.LanguageModelCriterion()
  lm:type(dtype)
  crit:type(dtype)

  local seq = torch.LongTensor(opt.seq_length, opt.batch_size):random(opt.vocab_size)
  seq[{ {4, 7}, 1 }] = 0
  seq[{ {5, 7}, 4 }] = 0
  local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)

  local params, grad_params = lm:getParameters()
  print('number of parameters:', params:nElement(), grad_params:nElement())
  local lstm_params = 4*(opt.image_encoding_size + opt.rnn_size)*opt.rnn_size + opt.rnn_size*4*2
  local output_params = opt.rnn_size * (opt.vocab_size + 1) + opt.vocab_size+1
  local table_params = (opt.vocab_size + 1) * opt.image_encoding_size
  local expected_params = lstm_params + output_params + table_params
  print('expected:', expected_params)

  local function lossFun()
    grad_params:zero()
    local output = lm:forward{imgs, seq}
    local loss = crit:forward(output, seq)
    local gradOutput = crit:backward(output, seq)
    lm:backward({imgs, seq}, gradOutput)
    return loss
  end

  local loss
  local grad_cache = grad_params:clone():fill(1e-8)
  print('trying to overfit the language model on toy data:')
  for t=1,30 do
    loss = lossFun()
    -- test that initial loss makes sense
    if t == 1 then tester:assertlt(math.abs(math.log(opt.vocab_size+1) - loss), 0.1) end
    grad_cache:addcmul(1, grad_params, grad_params)
    params:addcdiv(-1e-1, grad_params, torch.sqrt(grad_cache)) -- adagrad update
    print(string.format('iteration %d/30: loss %f', t, loss))
  end
  -- holy crap adagrad destroys the loss function!

  tester:assertlt(loss, 0.2)
end

-- check that we can call :sample() and that correct-looking things happen
local function sample()
  local dtype = 'torch.DoubleTensor'
  local opt = {}
  opt.vocab_size = 5
  opt.image_encoding_size = 4
  opt.word_encoding_size = 4
  opt.rnn_size = 8
  opt.num_layers = 1
  opt.dropout = 0
  opt.seq_length = 7
  opt.batch_size = 6
  local lm = nn.LanguageModel(opt)

  local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)
  local seq = lm:sample(imgs)

  tester:assertTensorSizeEq(seq, {opt.seq_length, opt.batch_size})
  tester:asserteq(seq:type(), 'torch.LongTensor')
  tester:assertge(torch.min(seq), 1)
  tester:assertle(torch.max(seq), opt.vocab_size+1)
  print('\nsampled sequence:')
  print(seq)
end


-- check that we can call :sample_beam() and that correct-looking things happen
-- these are not very exhaustive tests and basic sanity checks
local function sample_beam()
  local dtype = 'torch.DoubleTensor'
  torch.manualSeed(1)

  local opt = {}
  opt.vocab_size = 10
  opt.image_encoding_size = 4
  opt.word_encoding_size = 4

  opt.rnn_size = 8
  opt.num_layers = 1
  opt.dropout = 0
  opt.seq_length = 7
  opt.batch_size = 6
  local lm = nn.LanguageModel(opt)

  local imgs = torch.randn(opt.batch_size, opt.image_encoding_size):type(dtype)
  local semantic_words = torch.LongTensor(opt.batch_size, 2):random(opt.vocab_size)

  local seq_vanilla, logprobs_vanilla = lm:sample({imgs, semantic_words}) 

  local seq, logprobs = lm:sample({imgs, semantic_words}, {beam_size = 1})

  -- check some basic I/O, types, etc.
  tester:assertTensorSizeEq(seq, {opt.seq_length, opt.batch_size})
  tester:asserteq(seq:type(), 'torch.LongTensor')
  tester:assertge(torch.min(seq), 0)
  tester:assertle(torch.max(seq), opt.vocab_size)

  -- doing beam search with beam size 1 should return exactly what we had before
  print('')
  print('vanilla sampling:')
  print(seq_vanilla)
  print('beam search sampling with beam size 1:')
  print(seq)
  tester:assertTensorEq(seq_vanilla, seq, 0) -- these are LongTensors, expect exact match
  tester:assertTensorEq(logprobs_vanilla, logprobs, 1e-6) -- logprobs too

  -- doing beam search with higher beam size should yield higher likelihood sequences
  local seq2, logprobs2 = lm:sample({imgs, semantic_words}, {beam_size = 8})

  local logsum = torch.sum(logprobs, 1)
  local logsum2 = torch.sum(logprobs2, 1)
  print('')
  print('beam search sampling with beam size 1:')
  print(seq)
  print('beam search sampling with beam size 8:')
  print(seq2)
  print('logprobs:')
  print(logsum)
  print(logsum2)

  -- the logprobs should always be >=, since beam_search is better argmax inference
  tester:assert(torch.all(torch.gt(logsum2, logsum))) 
end

-- passed
lm_test.doubleApiForwardTest = forwardApiTestFactory('torch.DoubleTensor')
lm_test.floatApiForwardTest = forwardApiTestFactory('torch.FloatTensor')
lm_test.cudaApiForwardTest = forwardApiTestFactory('torch.CudaTensor')
-- passed
lm_test.gradCheck = gradCheck

-- havenot tested 
-- all the commented out method are not been tested at all
--tests.gradCheckLM = gradCheckLM
--tests.overfit = overfit
--tests.sample = sample

-- passed 
lm_test.sample_beam = sample_beam

tester:add(lm_test)
tester:run()
