-- ~/.config/nvim/lua/config/options.lua
-- LazyVim 会自动加载此文件
-- 此处用于设置 vim.opt 选项，覆盖 LazyVim 的默认设置或添加新设置

local opt = vim.opt

-- ==========================================
-- 通用外观与界面
-- ==========================================
opt.number = true -- 显示绝对行号
opt.relativenumber = true -- 显示相对行号 (方便跳转)
opt.cursorline = true -- 高亮当前行
opt.signcolumn = "yes" -- 始终显示符号列 (防止因诊断信息导致布局抖动)
opt.showmode = false -- 不显示模式 (因为状态栏通常会显示)
opt.breakindent = true -- 自动换行时保持缩进
opt.wrap = false -- 不换行 (代码过长时横向滚动，可根据喜好改为 true)
opt.scrolloff = 8 -- 光标距离屏幕上下边缘的最小行数
opt.sidescrolloff = 8 -- 光标距离屏幕左右边缘的最小列数
opt.termguicolors = true -- 启用真彩色支持
opt.colorcolumn = "80,120" -- 显示颜色列提示 (可根据项目规范调整)

-- ==========================================
-- 缩进与格式
-- ==========================================
opt.tabstop = 2 -- Tab 键相当于空格数
opt.shiftwidth = 2 -- 自动缩进的空格数
opt.softtabstop = 2 -- 退格键一次删除的空格数
opt.expandtab = true -- 将 Tab 转换为空格
opt.autoindent = true -- 自动缩进
opt.smartindent = true -- 智能缩进
opt.formatoptions:remove({ "c", "r", "o" }) -- 阻止在注释中自动插入注释符 (c), 回车后自动继续注释 (r), 使用 o/O 命令时自动插入注释符 (o)

-- ==========================================
-- 搜索与替换
-- ==========================================
opt.ignorecase = true -- 搜索时忽略大小写
opt.smartcase = true -- 如果搜索词包含大写字母，则区分大小写
opt.hlsearch = true -- 高亮搜索结果
opt.incsearch = true -- 实时搜索高亮
opt.inccommand = "split" -- 替换命令实时预览 (在分割窗口中)

-- ==========================================
-- 剪贴板与撤销
-- ==========================================
opt.clipboard = "unnamedplus" -- 使用系统剪贴板 (* 寄存器)
opt.undofile = true -- 启用持久化撤销
opt.undolevels = 10000 -- 增加撤销级别

-- ==========================================
-- 性能与备份
-- ==========================================
opt.swapfile = false -- 禁用交换文件 (LazyVim 默认可能已禁用，显式声明)
opt.backup = false -- 禁用备份文件
opt.writebackup = false -- 写入时不创建备份
opt.updatetime = 200 -- 减少更新间隔时间 (使插件响应更快，如 git 符号)
opt.timeoutlen = 300 -- 映射序列的超时时间 (毫秒)

-- ==========================================
-- 其他实用选项
-- ==========================================
opt.splitright = true -- 垂直分割窗口在右侧
opt.splitbelow = true -- 水平分割窗口在下方
opt.list = true -- 显示不可见字符 (需配合 listchars)
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" } -- 定义不可见字符的显示样式
opt.pumheight = 10 -- 弹出菜单的最大高度
opt.fileencoding = "utf-8" -- 文件编码
opt.cmdheight = 1 -- 命令行高度 (Neovim 0.9+ 推荐设为 0 或 1，LazyVim 通常处理得较好)
opt.completeopt = "menuone,noselect" -- 补全菜单行为：至少一个选项时显示菜单，不自动选择第一个

-- 注意：LazyVim 可能会在某些插件加载后再次修改某些选项。
-- 如果发现设置未生效，可能需要检查插件配置或使用 autocmd 在特定事件后设置。
