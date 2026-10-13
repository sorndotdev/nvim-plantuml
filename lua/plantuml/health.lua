local M = {}

M.check = function()
    vim.health.start('plantuml')

    if vim.fn.has('nvim-0.10') == 1 then
        vim.health.ok('Neovim >= 0.10')
    else
        vim.health.error('Neovim >= 0.10 is required (vim.uv, vim.system)')
    end

    local ok, plantuml = pcall(require, 'plantuml')
    if not ok then
        vim.health.error('plantuml module failed to load: ' .. tostring(plantuml))
        return
    end

    local d = plantuml.diagnostics()

    if d.java then
        local detail = d.java_version and (' (' .. d.java_version .. ')') or ''
        vim.health.ok('Java runtime: ' .. d.java .. detail)
    else
        vim.health.error('Java runtime not found', {
            'Install a JRE/JDK, or set the `java` option to its path',
            'On macOS /usr/bin/java is a stub: install a real JDK (e.g. `sdk install java` or `brew install openjdk`)',
        })
    end

    if d.jar then
        vim.health.ok('plantuml.jar: ' .. d.jar)
    elseif d.java then
        vim.health.warn('plantuml.jar not found', {
            'Run :PlantUMLInstall to download it, or set the `jar` option',
            'It is also downloaded automatically on first use',
        })
    else
        vim.health.error('plantuml.jar not found and no Java runtime to run it')
    end

    if d.graphviz then
        vim.health.ok('GraphViz `dot`: ' .. d.graphviz)
    else
        vim.health.warn('GraphViz `dot` not found', {
            'Some diagram types need GraphViz; install it or set the `graphviz` option',
        })
    end

    if d.magick then
        vim.health.ok('ImageMagick (`magick`): ' .. d.magick)
    else
        vim.health.info('ImageMagick (`magick`) not found: scale-to-fit is disabled')
    end

    if d.snacks then
        vim.health.ok('snacks.nvim image support available')
    else
        vim.health.error('snacks.nvim (with image support) is required to render the preview', {
            'https://github.com/folke/snacks.nvim',
        })
    end
end

return M
