--------------------------------------------------------------------------------
-- shell.lua: dumb ad-hoc code to work with sh-like shell
--------------------------------------------------------------------------------

require 'posix'

local assert, error, tostring
    = assert, error, tostring

local table_concat = table.concat

local os_execute = os.execute

local posix_fork, posix_exec, posix_pipe, posix_dup2, posix_wait, posix_close,
      posix_open, posix_read, posix_write, posix_WNOHANG, posix_BUFSIZ
    = posix.fork, posix.exec, posix.pipe, posix.dup2, posix.wait, posix.close,
      posix.open, posix.read, posix.write, posix.WNOHANG, posix.BUFSIZ

--------------------------------------------------------------------------------

local arguments,
      optional_arguments,
      method_arguments
      = import 'lua-nucleo/args.lua'
      {
        'arguments',
        'optional_arguments',
        'method_arguments'
      }

local is_number
      = import 'lua-nucleo/type.lua'
      {
        'is_number'
      }

local tset = import 'lua-nucleo/table-utils.lua' { 'tset' }

local make_concatter
      = import 'lua-nucleo/string.lua'
      {
        'make_concatter'
      }

--------------------------------------------------------------------------------

-- Standard descriptors
local STDIN_FILENO = 0
local STDOUT_FILENO = 1
local STDERR_FILENO = 2


local shell_escape -- Allowing shell substitutions to happen
local shell_escape_no_subst
do
  local passthrough = tset
  {
    "&&", "||";
    "(", ")";
    "{", "}";
    ">", ">>";
    "<", "<<";
  }

  shell_escape = function(s)
    if is_number(s) then
      return assert(tostring(s))
    end

    if s == "" then
      return "''"
    end

    if passthrough[s] then
      return s
    end

    s = s:gsub('"', '\\"')
    if s:find('[^A-Za-z0-9_."/%-]') then
      s = '"' .. s .. '"'
    end

    return s
  end

  -- TODO: Generalize with above
  shell_escape_no_subst = function(s)
    if is_number(s) then
      return assert(tostring(s))
    end

    if s == "" then
      return "''"
    end

    if passthrough[s] then
      return s
    end

    s = s:gsub("'", "\\'")
    if s:find("[^A-Za-z0-9_.'/%-]") then
      s = "'" .. s .. "'"
    end

    return s
  end
end

-- Allowing shell substitutions to happen
local function shell_escape_many(a1, a2, ...)
  if a2 == nil then
    return shell_escape(a1)
  end

  return shell_escape(a1), shell_escape_many(a2, ...)
end

local function shell_escape_many_no_subst(a1, a2, ...)
  if a2 == nil then
    return shell_escape_no_subst(a1)
  end

  return shell_escape_no_subst(a1), shell_escape_many_no_subst(a2, ...)
end

local shell_format_command = function(...)
  return table_concat({ shell_escape_many(...) }, " ") -- TODO: Avoid table creation
end

local shell_format_command_no_subst = function(...)
  return table_concat({ shell_escape_many_no_subst(...) }, " ") -- TODO: Avoid table creation
end

local shell_exec = function(...)
  local cmd = shell_format_command(...)
  -- print("executing:", cmd)
  return assert(os_execute(cmd))
end

local shell_exec_no_subst = function(...)
  local cmd = shell_format_command_no_subst(...)
  -- print("executing:", cmd)
  return assert(os_execute(cmd))
end

-- Convience wrapper around posix.wait, also ensure rc == 0
-- throwing error() if rc > 0 happens
local shell_wait = function(pid, cmd)
  local wpid, status, rc = posix_wait(pid)
  if wpid == pid  then
    if rc > 0 then
      error("command `" .. cmd .. "' stopped with rc==" .. rc)
    end
  else
    error("can't waid for `" .. cmd .. "' [" .. pid .. "]")
  end
end

-- Alternative io.popen, able to catch errors from subprocesses
-- Not compatible with popen, return blob with all output
-- Also, have different behavior with io.popen in lua 5.2, by closing stdin
-- of child process
local shell_read_popen = function(cmd)
  local rpipe, wpipe = posix_pipe()
  if rpipe == nil then
    local err = wpipe
    error("can't create pipe: " .. err)
  end

  local pid = posix_fork()
  if pid < 0 then
    error("can't fork")
  end
  if pid > 0 then
    -- in parent:
    -- close fd of "remote" side of pipe, we do not use it
    posix_close(wpipe)
    local cat, concat = make_concatter()
    while  true do
      local buf = posix_read(rpipe, posix_BUFSIZ)
      if buf == nil or #buf == 0 then
        break
      end
      cat(buf)
    end

    -- close our side of pipe
    posix_close(rpipe)

    -- wait child process, and check rc
    -- if wpid not equal pid then raise error
    shell_wait(pid, cmd)
    return concat()
  else
    -- in child process:

    -- force stdin = /dev/null
    local dev_null = posix_open("/dev/null", {}, "r")
    posix_dup2(dev_null, STDIN_FILENO)
    posix_close(dev_null)

    -- close "remote" side of pipe, and attach pipe to stdout
    posix_close(rpipe)
    posix_dup2(wpipe, STDOUT_FILENO)
    posix_close(wpipe)

    -- TODO: should explicitly close all descriptors, except 0,1,2
    -- GH#1 -- https://github.com/lua-aplicado/lua-aplicado/issues/1
    err, msg = posix_exec("/bin/sh", "-c", cmd)

    -- we can't raise exceptions here
    posix.write(STDERR_FILENO, "can't exec:" .. (msg or "unreachable") .. "\n")
    os.exit(1)
  end
end

local shell_read = function(...)
  return shell_read_popen(shell_format_command(...))
end

local shell_read_no_subst = function(...)
  return shell_read_popen(shell_format_command_no_subst(...))
end

--------------------------------------------------------------------------------

return
{
  shell_escape = shell_escape;
  shell_escape_many = shell_escape_many;
  shell_escape_no_subst = shell_escape_no_subst;
  shell_escape_many_no_subst = shell_escape_many_no_subst;
  shell_format_command = shell_format_command;
  shell_format_command_no_subst = shell_format_command_no_subst;
  shell_exec = shell_exec;
  shell_exec_no_subst = shell_exec_no_subst;
  shell_read = shell_read;
  shell_read_no_subst = shell_read_no_subst;
}
