-- PlantUML live preview.
--
--   :PlantUMLPreview [right|left|top|bottom]
--   :PlantUMLPreviewToggle
--   :PlantUMLPreviewClose
--   :PlantUMLStop
--
-- Renders the first @start/@end block of a .puml buffer with a persistent
-- `plantuml -pipe` process and shows the PNG in a split via snacks.image.
--
-- Rendering needs a PlantUML jar (run through `java`). The jar is downloaded on
-- demand into `stdpath('data')/plantuml/` via :PlantUMLInstall, or you can point
-- `jar` at your own copy, drop one in vendor/, or use an external `plantuml`.
-- Only a Java runtime is required on the system.

local M = {}

-- Repository root, derived from this file's location (lua/plantuml/init.lua).
local plugin_root = (function()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(src, ':h:h:h')
end)()

M.config = {
    enabled = true,
    -- Path to an external `plantuml` executable. When nil, a local jar or a
    -- `plantuml` on $PATH is used.
    bin = nil,
    -- Path to plantuml.jar. When nil, a jar in vendor/ or the downloaded copy
    -- under stdpath('data')/plantuml/ is used.
    jar = nil,
    -- Where :PlantUMLInstall downloads the jar from (pinned release).
    jar_url = 'https://github.com/plantuml/plantuml/releases/download/v1.2026.8/plantuml-1.2026.8.jar',
    -- Expected SHA-256 of the downloaded jar. Set to false to skip verification.
    jar_sha256 = '5e1ecfa8ecd32c90b03bbf3b1eb6f020943f98ab0fcf4032be31a0002ee2c462',
    -- Download the jar automatically on first use when it is missing.
    auto_install = true,
    -- Java runtime used to run the jar.
    java = 'java',
    -- Path to GraphViz `dot` (needed by some diagram types). Auto-detected.
    graphviz = nil,
    args = { '-pipe', '-tpng', '-nometadata' },
    position = 'right',
    size = 0.4,
    auto_open = true,
    debounce = 300,
    batch_size = 10,
    batch_ttl = 2000,
    keymaps = true,
    stop_when_closed = true,
    fill = true,
    max_scale = 4,
}

local IEND = '\0\0\0\0IEND\xae\x42\x60\x82'
local states = {}
local render
local session_id = string.format('%x-%x', vim.fn.getpid(), os.time())

local function notify(msg, level)
    local line = '@plantuml: ' .. msg
    if vim.in_fast_event() then
        vim.schedule(function()
            vim.notify(line, level or vim.log.levels.INFO)
        end)
    else
        vim.notify(line, level or vim.log.levels.INFO)
    end
end

local function image_module()
    local ok, snacks = pcall(require, 'snacks')
    if ok and snacks.image then
        return snacks.image
    end
end

-- Resolve an executable from config, which may be a bare command name (found on
-- $PATH) or a path (expanded, with ~ support). No hardcoded system paths.
local function resolve_exe(value)
    if type(value) ~= 'string' or value == '' then
        return
    end
    local path = vim.fn.exepath(value)
    if path ~= '' then
        return path
    end
    local expanded = vim.fn.expand(value)
    if vim.fn.executable(expanded) == 1 then
        return expanded
    end
end

local function java_probe(path)
    local ok, res = pcall(function()
        return vim.system({ path, '-version' }, { text = true }):wait()
    end)
    if not ok or type(res) ~= 'table' then
        return
    end
    local out = (res.stdout or '') .. (res.stderr or '')
    if res.code == 0 and out:find('version', 1, true) then
        return vim.trim((vim.split(out, '\n', { plain = true })[1] or ''))
    end
end

local java_cache
local function java_bin()
    if java_cache == nil then
        local path = resolve_exe(M.config.java)
        local version = path and java_probe(path)
        java_cache = (version and { path = path, version = version }) or false
    end
    if java_cache then
        return java_cache.path
    end
end

local function java_version()
    java_bin()
    if java_cache then
        return java_cache.version
    end
end

local function dot_bin()
    if M.config.graphviz then
        return resolve_exe(M.config.graphviz)
    end
    return resolve_exe('dot')
end

local function data_dir()
    return vim.fn.stdpath('data') .. '/plantuml'
end

local function downloaded_jar()
    return data_dir() .. '/plantuml.jar'
end

-- A locally available jar: an explicit `jar`, a jar dropped in vendor/, or the
-- copy downloaded by :PlantUMLInstall.
local function jar_path()
    if M.config.jar then
        local jar = vim.fn.expand(M.config.jar)
        if vim.fn.filereadable(jar) == 1 then
            return jar
        end
    end
    local vendor = plugin_root .. '/vendor/plantuml.jar'
    if vim.fn.filereadable(vendor) == 1 then
        return vendor
    end
    local dl = downloaded_jar()
    if vim.fn.filereadable(dl) == 1 then
        return dl
    end
end

-- Returns { exe = <executable>, args = { ... } } for spawning the renderer.
local function resolve_cmd()
    if M.config.bin then
        local bin = resolve_exe(M.config.bin)
        if bin then
            return { exe = bin, args = vim.deepcopy(M.config.args) }
        end
    end

    local jar = jar_path()
    local java = java_bin()
    if jar and java then
        local args = { '-jar', jar }
        vim.list_extend(args, vim.deepcopy(M.config.args))
        return { exe = java, args = args }
    end

    local bin = resolve_exe('plantuml')
    if bin then
        return { exe = bin, args = vim.deepcopy(M.config.args) }
    end
end

local installing = false
local install_waiters = {}

local function sha256_file(path)
    local ok, blob = pcall(vim.fn.readblob, path)
    if not ok or not blob or vim.fn.len(blob) == 0 then
        return
    end
    return vim.fn.sha256(blob)
end

local function download(url, dest, cb)
    vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
    local tmp = dest .. '.part'
    pcall(vim.fn.delete, tmp)
    local curl = resolve_exe('curl')
    local wget = resolve_exe('wget')
    local cmd
    if curl then
        cmd = { curl, '-fL', '--retry', '3', '--retry-delay', '1', '-o', tmp, url }
    elseif wget then
        cmd = { wget, '-q', '-O', tmp, url }
    else
        return cb(false, 'neither curl nor wget is available')
    end
    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                pcall(vim.fn.delete, tmp)
                return cb(false, vim.trim(res.stderr or ('exit ' .. tostring(res.code))))
            end
            if M.config.jar_sha256 then
                local got = sha256_file(tmp)
                if got ~= M.config.jar_sha256 then
                    pcall(vim.fn.delete, tmp)
                    return cb(false, 'checksum mismatch (expected '
                        .. M.config.jar_sha256 .. ', got ' .. tostring(got) .. ')')
                end
            end
            if vim.fn.rename(tmp, dest) ~= 0 then
                pcall(vim.fn.delete, tmp)
                return cb(false, 'failed to move the downloaded jar into place')
            end
            cb(true)
        end)
    end)
end

--- Download plantuml.jar into stdpath('data')/plantuml/plantuml.jar.
---@param cb? fun(ok:boolean, err?:string)
function M.install(cb)
    if jar_path() then
        if cb then
            cb(true)
        end
        return
    end
    if installing then
        if cb then
            install_waiters[#install_waiters + 1] = cb
        end
        return
    end
    if not java_bin() then
        local msg = 'no Java runtime found; install a JRE/JDK or set `java`'
        notify(msg, vim.log.levels.ERROR)
        if cb then
            cb(false, msg)
        end
        return
    end
    installing = true
    if cb then
        install_waiters[#install_waiters + 1] = cb
    end
    notify('downloading plantuml.jar ...')
    download(M.config.jar_url, downloaded_jar(), function(ok, err)
        installing = false
        local waiters = install_waiters
        install_waiters = {}
        if ok then
            notify('plantuml.jar installed')
        else
            notify('failed to install plantuml.jar: ' .. tostring(err), vim.log.levels.ERROR)
        end
        for _, waiter in ipairs(waiters) do
            waiter(ok, err)
        end
        if ok then
            for _, state in pairs(states) do
                if state.pending then
                    render(state)
                end
            end
        end
    end)
end

--- Resolve dependency locations for :checkhealth and :PlantUMLDebug.
---@return table
function M.diagnostics()
    local cmd = resolve_cmd()
    local ok_snacks, snacks = pcall(require, 'snacks')
    return {
        cmd = cmd and (cmd.exe .. ' ' .. table.concat(cmd.args, ' ')) or nil,
        jar = jar_path(),
        downloaded_jar = downloaded_jar(),
        java = java_bin(),
        java_version = java_version(),
        graphviz = dot_bin(),
        magick = resolve_exe('magick'),
        snacks = ok_snacks and snacks.image ~= nil,
        data_dir = data_dir(),
    }
end

local function win_for(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
end

local function current_state()
    local buf = vim.api.nvim_get_current_buf()
    if states[buf] then
        return states[buf]
    end
    for _, state in pairs(states) do
        if state.preview_buf == buf then
            return state
        end
    end
end

local function extract_diagram(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local first, last
    for i, line in ipairs(lines) do
        if not first and line:match('^%s*@start') then
            first = i
        elseif first and line:match('^%s*@end') then
            last = i
            break
        end
    end
    if not first or not last then
        return
    end
    return table.concat(vim.list_slice(lines, first, last), '\n') .. '\n'
end

local function png_dims(png)
    if #png < 24 then
        return
    end
    local w = png:byte(17) * 16777216 + png:byte(18) * 65536 + png:byte(19) * 256 + png:byte(20)
    local h = png:byte(21) * 16777216 + png:byte(22) * 65536 + png:byte(23) * 256 + png:byte(24)
    if w and h and w > 0 and h > 0 then
        return { w = w, h = h }
    end
end

local function pane_pixels(state)
    local win = state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) and win_for(state.preview_buf)
    if not win then
        return
    end
    local image = image_module()
    local size = image and image.terminal.size()
    local cw = size and size.cell_width or 0
    local ch = size and size.cell_height or 0
    if not cw or cw <= 0 then
        cw = 9
    end
    if not ch or ch <= 0 then
        ch = 18
    end
    return vim.api.nvim_win_get_width(win) * cw, vim.api.nvim_win_get_height(win) * ch
end

local function fit_size(w, h, pw, ph)
    local scale = math.min(pw / w, ph / h)
    return math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5))
end

local function resize_png(state, src, w, h)
    local bin = vim.fn.exepath('magick')
    if bin == '' then
        return
    end
    local dir = vim.fn.stdpath('cache') .. '/plantuml'
    vim.fn.mkdir(dir, 'p')
    state.seq = state.seq + 1
    local out = string.format('%s/%d-%s-%d.png', dir, state.src_buf, session_id, state.seq)
    vim.fn.system({ bin, src, '-resize', string.format('%dx%d!', w, h), out })
    if vim.v.shell_error ~= 0 or vim.fn.filereadable(out) == 0 then
        return
    end
    return out
end

local function display_path(state, src, dims)
    local pw, ph = pane_pixels(state)
    if not pw or pw == 0 or ph == 0 then
        return src
    end
    local tw, th = fit_size(dims.w, dims.h, pw, ph)
    if math.abs(tw - dims.w) <= dims.w * 0.05 and math.abs(th - dims.h) <= dims.h * 0.05 then
        return src
    end
    return resize_png(state, src, tw, th) or src
end

local function maybe_rescale(state)
    if not M.config.fill or state.user_scale then
        return false
    end
    local dims = state.last_dims
    local pw, ph = pane_pixels(state)
    if not dims or not pw or pw == 0 or ph == 0 then
        return false
    end
    local used = dims.scale
    local want = math.min(used * math.min(pw / dims.w, ph / dims.h), M.config.max_scale)
    if math.abs(want - used) > used * 0.15 then
        state.scale = want
        return true
    end
    return false
end

local function with_scale(state, diagram)
    local scale = math.min(state.scale or 1, M.config.max_scale)
    if not M.config.fill or math.abs(scale - 1) < 0.01 then
        return diagram
    end
    if diagram:match('\n%s*scale[%s%*]') then
        return diagram
    end
    local head, rest = diagram:match('^([^\n]*\n)(.*)$')
    if not head then
        return diagram
    end
    return head .. string.format('scale %.3f\n', scale) .. rest
end

local function stop_proc(state)
    state.rendering = false
    state.pending = false
    state.stdout_buf = {}
    state.last_err = nil
    if state.err_timer then
        state.err_timer:stop()
    end
    if state.proc then
        pcall(function() state.proc:kill('sigterm') end)
        pcall(function() state.proc:close() end)
        state.proc = nil
    end
    for _, handle in ipairs({ state.stdin, state.stdout, state.stderr }) do
        if handle then
            pcall(function() handle:read_stop() end)
            pcall(function() handle:close() end)
        end
    end
    state.stdin, state.stdout, state.stderr = nil, nil, nil
end

local function refresh(state, path)
    local image = image_module()
    if not image or not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
        return
    end
    image.buf.attach(state.preview_buf, { src = path })
end

local function on_png(state, png)
    state.rendering = false
    state.seq = state.seq + 1
    local dir = vim.fn.stdpath('cache') .. '/plantuml'
    vim.fn.mkdir(dir, 'p')
    local path = string.format('%s/%d-%s-%d.png', dir, state.src_buf, session_id, state.seq)
    local fd = io.open(path, 'wb')
    if not fd then
        notify('failed to write ' .. path, vim.log.levels.ERROR)
        return
    end
    fd:write(png)
    fd:close()

    local dims = png_dims(png)
    local display = path
    if dims then
        state.last_dims = { w = dims.w, h = dims.h, scale = state.scale or 1 }
        display = display_path(state, path, dims)
        if maybe_rescale(state) then
            state.pending = true
        end
    end

    refresh(state, display)
    if state.last_path and state.last_path ~= display then
        vim.fn.delete(state.last_path)
    end
    state.last_path = display
    if state.orig_path and state.orig_path ~= path then
        vim.fn.delete(state.orig_path)
    end
    state.orig_path = path

    if state.pending then
        state.pending = false
        render(state)
    end
end

local function queue_error(state, line)
    state.err_lines = state.err_lines or {}
    state.err_lines[#state.err_lines + 1] = line
    state.err_timer = state.err_timer or vim.uv.new_timer()
    state.err_timer:stop()
    state.err_timer:start(200, 0, vim.schedule_wrap(function()
        local msg = table.concat(state.err_lines, '\n')
        state.err_lines = {}
        if msg ~= '' and msg ~= state.last_err then
            state.last_err = msg
            notify(msg, vim.log.levels.WARN)
        end
    end))
end

local function child_env()
    local environ = vim.fn.environ()
    local headless = environ.JAVA_TOOL_OPTIONS or ''
    if not headless:find('java.awt.headless', 1, true) then
        headless = headless == '' and '-Djava.awt.headless=true' or (headless .. ' -Djava.awt.headless=true')
    end
    local env = {}
    for key, value in pairs(environ) do
        if key ~= 'JAVA_TOOL_OPTIONS' and key ~= 'GRAPHVIZ_DOT' then
            env[#env + 1] = key .. '=' .. value
        end
    end
    env[#env + 1] = 'JAVA_TOOL_OPTIONS=' .. headless
    local dot = dot_bin()
    if dot then
        env[#env + 1] = 'GRAPHVIZ_DOT=' .. dot
    end
    return env
end

local function start_proc(state)
    if state.proc then
        return true
    end
    local cmd = resolve_cmd()
    if not cmd then
        if M.config.auto_install and java_bin() then
            state.pending = true
            M.install()
        else
            notify('PlantUML not found: no jar, no external `plantuml`, or no Java runtime', vim.log.levels.ERROR)
        end
        return false
    end
    local name = vim.api.nvim_buf_get_name(state.src_buf)
    local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
    local stdin = vim.uv.new_pipe(false)
    local stdout = vim.uv.new_pipe(false)
    local stderr = vim.uv.new_pipe(false)
    local proc
    proc = vim.uv.spawn(cmd.exe, {
        args = cmd.args,
        cwd = dir,
        env = child_env(),
        stdio = { stdin, stdout, stderr },
    }, function()
        if state.proc == proc then
            state.proc = nil
        end
        pcall(function() proc:close() end)
        stop_proc(state)
    end)
    if not proc then
        stdin:close()
        stdout:close()
        stderr:close()
        notify('failed to start ' .. cmd.exe, vim.log.levels.ERROR)
        return false
    end
    state.proc = proc
    state.stdin = stdin
    state.stdout = stdout
    state.stderr = stderr
    state.stdout_buf = {}

    stdout:read_start(function(_, data)
        if not data then
            return
        end
        local buf = state.stdout_buf
        buf[#buf + 1] = data
        local joined = table.concat(buf)
        local idx = joined:find(IEND, 1, true)
        if idx then
            local png = joined:sub(1, idx + #IEND - 1)
            state.stdout_buf = { joined:sub(idx + #IEND) }
            vim.schedule(function()
                on_png(state, png)
            end)
        end
    end)

    stderr:read_start(function(_, data)
        if not data then
            return
        end
        for line in vim.gsplit(data, '\n', { plain = true }) do
            line = vim.trim(line)
            if line ~= '' and not line:match('^Picked up ') then
                queue_error(state, line)
            end
        end
    end)

    return true
end

function render(state)
    if not vim.api.nvim_buf_is_valid(state.src_buf) then
        return
    end
    local diagram = extract_diagram(state.src_buf)
    if not diagram then
        return
    end
    if state.rendering then
        state.pending = true
        return
    end
    state.user_scale = diagram:match('\n%s*scale[%s%*]') ~= nil
    if not start_proc(state) then
        return
    end
    state.rendering = true
    state.stdin:write(with_scale(state, diagram))
end

local function batch_reset(state)
    state.pending_changes = 0
    if state.timer then
        state.timer:stop()
    end
    if state.flush_timer then
        state.flush_timer:stop()
    end
end

local function schedule_render_soon(state, delay)
    batch_reset(state)
    state.timer = state.timer or vim.uv.new_timer()
    state.timer:start(delay or M.config.debounce, 0, vim.schedule_wrap(function()
        render(state)
    end))
end

local function schedule_render(state)
    state.pending_changes = (state.pending_changes or 0) + 1
    if state.pending_changes >= M.config.batch_size then
        state.flush_timer = state.flush_timer or vim.uv.new_timer()
        state.flush_timer:stop()
        state.flush_timer:start(0, 0, vim.schedule_wrap(function()
            batch_reset(state)
            render(state)
        end))
        return
    end
    if state.pending_changes == 1 then
        state.timer = state.timer or vim.uv.new_timer()
        state.timer:stop()
        state.timer:start(M.config.batch_ttl, 0, vim.schedule_wrap(function()
            batch_reset(state)
            render(state)
        end))
    end
end

local function refresh_display(state)
    if not state.orig_path or not state.last_dims or vim.fn.filereadable(state.orig_path) == 0 then
        return
    end
    local display = display_path(state, state.orig_path, state.last_dims)
    if display == state.last_path then
        return
    end
    refresh(state, display)
    if state.last_path and state.last_path ~= display then
        vim.fn.delete(state.last_path)
    end
    state.last_path = display
end

local function schedule_display(state)
    state.display_timer = state.display_timer or vim.uv.new_timer()
    state.display_timer:stop()
    state.display_timer:start(200, 0, vim.schedule_wrap(function()
        refresh_display(state)
    end))
end

local function preview_open(state, position)
    position = position or M.config.position
    if position ~= 'left' and position ~= 'top' and position ~= 'bottom' then
        position = 'right'
    end
    if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
        state.preview_buf = vim.api.nvim_create_buf(false, true)
        pcall(vim.api.nvim_buf_set_name, state.preview_buf, 'plantuml://preview/' .. state.src_buf)
        vim.bo[state.preview_buf].bufhidden = 'hide'
    end
    local win = win_for(state.preview_buf)
    if win and position ~= state.position then
        vim.api.nvim_win_close(win, true)
        win = nil
    end
    if not win then
        local previous = vim.api.nvim_get_current_win()
        local split = position == 'left' and 'topleft vsplit'
            or position == 'top' and 'topleft split'
            or position == 'bottom' and 'botright split'
            or 'botright vsplit'
        vim.cmd(split)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, state.preview_buf)
        if position == 'left' or position == 'right' then
            vim.cmd('vertical resize ' .. math.max(20, math.floor(vim.o.columns * M.config.size)))
        else
            vim.cmd('resize ' .. math.max(5, math.floor(vim.o.lines * M.config.size)))
        end
        if vim.api.nvim_win_is_valid(previous) and vim.api.nvim_win_get_buf(previous) ~= state.preview_buf then
            vim.api.nvim_set_current_win(previous)
        end
        state.position = position
        vim.api.nvim_create_autocmd('WinClosed', {
            pattern = tostring(win),
            once = true,
            callback = function()
                vim.schedule(function()
                    if not (state.preview_buf and win_for(state.preview_buf)) then
                        if M.config.stop_when_closed then
                            stop_proc(state)
                        end
                    end
                end)
            end,
        })
    end
    if state.last_path then
        refresh(state, state.last_path)
        if maybe_rescale(state) then
            schedule_render_soon(state)
        else
            schedule_display(state)
        end
    end
    return win
end

local function preview_close(state)
    if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
        local image = image_module()
        if image then
            image.placement.clean(state.preview_buf)
        end
        local win = win_for(state.preview_buf)
        if win then
            vim.api.nvim_win_close(win, true)
        end
        pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
    end
    state.preview_buf = nil
    state.position = nil
    if M.config.stop_when_closed then
        stop_proc(state)
    end
end

local function setup_buffer(buf)
    if states[buf] then
        return states[buf]
    end
    local state = { src_buf = buf, seq = 0 }
    states[buf] = state
    for _, stale in ipairs(vim.fn.glob(vim.fn.stdpath('cache') .. '/plantuml/' .. buf .. '-*.png', false, true)) do
        vim.fn.delete(stale)
    end
    if M.config.auto_open then
        preview_open(state)
    end
    schedule_render_soon(state, 100)
    return state
end

function M.toggle(buf)
    local state = current_state() or (buf and states[buf])
    if not state then
        buf = buf or vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= 'plantuml' then
            notify('not a plantuml buffer')
            return
        end
        state = setup_buffer(buf)
    end
    if state.preview_buf and win_for(state.preview_buf) then
        preview_close(state)
    else
        preview_open(state)
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

vim.filetype.add({
    extension = { puml = 'plantuml', plantuml = 'plantuml', iuml = 'plantuml' },
})

local augroup = vim.api.nvim_create_augroup('plantuml-preview', { clear = true })

vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = 'plantuml',
    callback = function(args)
        if not M.config.enabled then
            return
        end
        setup_buffer(args.buf)
        if M.config.keymaps then
            vim.keymap.set('n', '<leader>up', function()
                M.toggle(args.buf)
            end, { buffer = args.buf, desc = 'PlantUML preview' })
        end
    end,
})

vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'InsertLeave', 'BufWritePost' }, {
    group = augroup,
    callback = function(args)
        local state = states[args.buf]
        if state then
            schedule_render(state)
        end
    end,
})

vim.api.nvim_create_autocmd('WinResized', {
    group = augroup,
    callback = function()
        for _, state in pairs(states) do
            if state.last_dims and state.preview_buf and win_for(state.preview_buf) then
                if maybe_rescale(state) then
                    schedule_render_soon(state)
                else
                    schedule_display(state)
                end
            end
        end
    end,
})

vim.api.nvim_create_autocmd('BufWipeout', {
    group = augroup,
    callback = function(args)
        local state = states[args.buf]
        if state then
            states[args.buf] = nil
            if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
                pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
            end
            stop_proc(state)
            if state.timer then
                state.timer:stop()
                state.timer:close()
                state.timer = nil
            end
            if state.flush_timer then
                state.flush_timer:stop()
                state.flush_timer:close()
                state.flush_timer = nil
            end
            if state.err_timer then
                state.err_timer:stop()
                state.err_timer:close()
                state.err_timer = nil
            end
            if state.display_timer then
                state.display_timer:stop()
                state.display_timer:close()
                state.display_timer = nil
            end
        end
    end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
        for _, state in pairs(states) do
            stop_proc(state)
        end
    end,
})

vim.api.nvim_create_user_command('PlantUMLPreview', function(args)
    local state = current_state()
    if not state then
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= 'plantuml' then
            notify('not a plantuml buffer')
            return
        end
        state = setup_buffer(buf)
    end
    preview_open(state, args.args ~= '' and args.args or nil)
end, {
    nargs = '?',
    complete = function()
        return { 'right', 'left', 'top', 'bottom' }
    end,
    desc = 'Open the PlantUML preview split',
})

vim.api.nvim_create_user_command('PlantUMLPreviewToggle', function()
    M.toggle()
end, { desc = 'Toggle the PlantUML preview split' })

vim.api.nvim_create_user_command('PlantUMLPreviewClose', function()
    local state = current_state()
    if state then
        preview_close(state)
    end
end, { desc = 'Close the PlantUML preview split' })

vim.api.nvim_create_user_command('PlantUMLStop', function()
    for _, state in pairs(states) do
        stop_proc(state)
    end
end, { desc = 'Stop PlantUML render processes' })

vim.api.nvim_create_user_command('PlantUMLInstall', function()
    M.install(function(ok, err)
        if not ok then
            notify('install failed: ' .. tostring(err), vim.log.levels.ERROR)
        end
    end)
end, { desc = 'Download plantuml.jar into stdpath("data")' })

vim.api.nvim_create_user_command('PlantUMLDebug', function()
    local state = current_state()
    local d = M.diagnostics()
    local lines = {
        'cmd: ' .. (d.cmd or 'not found'),
        'jar: ' .. (d.jar or 'not found'),
        'java: ' .. (d.java or 'not found') .. (d.java_version and (' (' .. d.java_version .. ')') or ''),
        'graphviz: ' .. (d.graphviz or 'not found'),
        'magick: ' .. (d.magick or 'not found'),
        'snacks: ' .. (d.snacks and 'yes' or 'no'),
        'fill: ' .. tostring(M.config.fill) .. '  max_scale: ' .. tostring(M.config.max_scale),
    }
    if state then
        local pw, ph = pane_pixels(state)
        lines[#lines + 1] = 'scale: ' .. tostring(state.scale)
        lines[#lines + 1] = 'rendered: ' .. (state.last_dims and (state.last_dims.w .. 'x' .. state.last_dims.h) or 'none')
        lines[#lines + 1] = 'pane: ' .. tostring(pw) .. 'x' .. tostring(ph) .. ' px'
        lines[#lines + 1] = 'display: ' .. tostring(state.last_path)
    else
        lines[#lines + 1] = 'no active plantuml buffer'
    end
    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end, { desc = 'Show PlantUML preview diagnostics' })

return M
