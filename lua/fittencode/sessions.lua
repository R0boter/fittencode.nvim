local fn = vim.fn

local Base = require('fittencode.base')
local Client = require('fittencode.client.fitten')
local Config = require('fittencode.config')
local KeyStorage = require('fittencode.key_storage')
local Log = require('fittencode.log')
local Path = require('fittencode.fs.path')
local PromptProviders = require('fittencode.prompt_providers')

local schedule = Base.schedule

local M = {}

local KEY_STORE_PATH = Path.to_native(fn.stdpath('data') .. '/fittencode' .. '/api_key.json')

---@type FittenClient
local client = nil

---@type KeyStorage
local key_storage = nil

-- Current user name, used for mapping to API key
---@type string?
local current_username = nil

function M.register()
  client:register()
end

---@param username? string
---@param password? string
function M.login(username, password)
  local invalid = function()
    return username == nil or username == '' or password == nil or password == ''
  end
  if invalid() then
    username = fn.input('Username ')
    password = fn.inputsecret('Password ')
  end
  if invalid() then
    Log.e('Invalid username or password')
    return
  end

  current_username = username

  local api_key = key_storage:get_key_by_name(current_username)
  if api_key ~= nil then
    Log.i('You are already logged in')
    return
  end

  client:login(current_username, password, function(key)
    key_storage:set_key_by_name(current_username, key)
    Log.i('Login successful')
  end, function()
    Log.e('Failed to login with provided credentials')
  end)
end

function M.logout()
  local api_key = key_storage:get_key_by_name(current_username)
  if api_key == nil then
    Log.i('You are already logged out')
    return
  end
  key_storage:clear()
  current_username = nil
  Log.i('Logout successful')
end

function M.load_last_session()
  -- Log.info('Loading last session...')
  key_storage:load(function(name)
    current_username = name
    Log.info('Last session for user {} loaded successful', name)
  end, function()
    Log.info('Last session not found or invalid')
  end)
end

---@alias Suggestions string[] Formated suggesion

---@param generated_text string
---@return Suggestions?
local function generate_suggestions(generated_text)
  local generated_text = fn.substitute(generated_text, '<.endoftext.>', '', 'g') or ''
  local lines = vim.split(generated_text, '\r')
  if vim.tbl_count(lines) == 0 or (vim.tbl_count(lines) == 1 and string.len(lines[1]) == 0) then
    return
  end

  if string.len(lines[#lines]) == 0 then
    table.remove(lines, #lines)
  end

  ---@type Suggestions
  local suggestions = {}
  for _, line in ipairs(lines) do
    local parts = vim.split(line, '\n')
    for _, part in ipairs(parts) do
      table.insert(suggestions, part)
    end
  end
  return suggestions
end

---@return table?, table?
local function make_generate_one_stage_params(opts)
  local prompt = PromptProviders.get_prompt_one(opts)
  if prompt == nil then
    return
  end
  if prompt.within_the_line and Config.options.inline_completion.disable_completion_within_the_line then
    return
  end
  local fc_prompt = '!FCPREFIX!' .. prompt.prefix .. '!FCSUFFIX!' .. prompt.suffix .. '!FCMIDDLE!'
  local escaped_fc_prompt = string.gsub(fc_prompt, '"', '\\"')
  local params = {
    inputs = escaped_fc_prompt,
    meta_datas = {
      filename = prompt.filename,
    },
  }
  return params, prompt
end

function M.ready_for_generate()
  return key_storage:get_key_by_name(current_username) ~= nil
end

---@param timestamp integer
---@param on_success function|nil
---@param on_error function|nil
function M.request_generate_one_stage(timestamp, opts, on_success, on_error)
  local api_key = key_storage:get_key_by_name(current_username)
  if api_key == nil then
    -- Log.debug('Key is not found')
    schedule(on_error)
    return
  end
  local params, prompt = make_generate_one_stage_params(opts)
  if params == nil then
    schedule(on_error)
    return
  end

  client:generate_one_stage(api_key, params, function(generated_text)
    schedule(on_success, timestamp, prompt, generate_suggestions(generated_text))
  end, on_error)
end

function M.setup()
  client = Client:new()
  -- Log.debug('FittenClient rest implementation is: {}', client:get_restimpl_name())
  key_storage = KeyStorage:new({
    path = KEY_STORE_PATH,
  })
end

return M
