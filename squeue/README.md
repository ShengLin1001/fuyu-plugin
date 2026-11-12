# 作业队列

看你在超算上排队和运行的 Slurm 作业。收起条上显示所有电脑合计的状态，岛上多一个「作业」页面，按电脑列出每个作业。

## 查哪些电脑

- 浮屿 设置 → AI Agent → 远程电脑 里勾选的电脑。和 Agent 远程会话共用这份列表，勾选或取消后插件几秒内跟上，不用另外配置。
- 本机的 WSL：只在默认发行版**已经启动**、并且里面装了 `squeue` 时才查。插件不会为了查队列去启动 WSL；没有 Slurm 的 WSL 不显示。
- 只看自己的作业（`squeue -u <你的用户名>`）。

登录用你已有的 SSH 密钥（`BatchMode`，不会弹密码框），选项和浮屿自己连远程电脑时一样，并且不重复打开你在 `~/.ssh/config` 里配的隧道。ssh 启动的是登录 shell，所以 `module load` 之类的环境和你平时登录时一样。插件只运行 `squeue`，不改远程电脑上的任何东西。

## 收起条

- 一个饼图，按所有电脑合计的作业数分块：R 绿、PD 橙、CG 蓝、其他（CF、S 等）品红。鼠标停在上面显示每种状态各有几个；有电脑查询失败时，悬停提示里写出是哪台、失败了多久。
- 饼图需要支持「收起条上的饼图」的岛屿；旧版岛屿显示成文字，如 `R12 PD3 CG1 +2`（`+2` 是其他状态的作业数）。
- 有电脑连续失败超过 5 分钟时，文字末尾加 `!` 并变黄。
- 可以在 外观 → 收起条上的项目 里调位置或隐藏。

## 「作业」页面

- 按电脑分组（WSL 在最前，其余按岛里勾选的顺序），组可以折叠，组标题旁是这台电脑的各状态数量。
- 每个作业一行：状态、作业名、已运行 / 时限（排队中的作业显示排队原因），第二行是工作目录的最后三级；鼠标停在目录上显示完整路径。
- 点一个作业展开：作业 ID、分区、节点数、CPU、GPU、提交时间、开始时间（排队中是 Slurm 预估的开始时间）、排队原因或节点列表、完整工作目录（可以选中复制）。
- 不想在主面板里看到这一页，在 设置 → 插件扩展 → 岛上页面 里隐藏。

## 多久查一次，失败了怎么办

- 每 60 秒查一轮，各台电脑同时查。
- `squeue` 偶尔会失败（slurmctld 忙、网络抖动）。某台失败后每 5 秒重试一次，最多 99 次（约 8 分钟），之后回到每 60 秒一次，直到成功。
- 失败期间这台电脑继续显示上次查到的作业，页面上标明「查询失败、正在重试」和原因。只有退出码为 0 的 `squeue` 才算数：失败时的空输出不会被当成「队列已空」。
- 已经离开队列的作业 `squeue` 看不到，所以页面上不会有已完成的作业。

## 开销

插件一直运行（收起条上的项目在插件停止时会被清空），是一个 Windows 自带的 PowerShell 进程。每台电脑每分钟一次 ssh 登录，查询失败时每 5 秒一次；登录节点如果开了 fail2ban 之类的限制，连续失败时可能被临时封禁。

## 已知限制

- 远程电脑列表读的是浮屿自己的文件 `agent-remote-hosts.json`（插件数据目录往上两级），不是插件 API；浮屿改了这个文件的格式时，页面上会显示「读不到远程电脑列表」。
- 作业名里有 `|` 时，这个作业后面几个字段会错位。

## 开发

在仓库根目录 `npm install`，再 `npm test`（只在 Windows 上跑）；只测这个插件就在本目录运行 `node --test`。测试用 `test/fake-ssh` 代替 ssh，模拟正常、队列为空、第一次失败、连不上四种电脑。

## 权限

不需要任何权限。

## English

Your own Slurm jobs on the computers ticked under Fuyu's Settings > AI Agent > Remote computers, and in WSL when it is already running and has `squeue`. The collapsed bar shows a pie of the totals over all computers (R green, PD orange, CG blue, other magenta; older islands show text such as `R12 PD3 CG1 +2`) with the counts on hover. The Jobs page lists every job by computer: state, name, elapsed / limit (or why it waits), the last three folders of its working directory (hover for the full path); click a job for partition, nodes, CPUs, GPUs, submit and start times and the node list. Each computer is asked every 60 seconds; a failed query is retried every 5 seconds up to 99 times while the last answer stays on the page, and only a clean `squeue` exit counts, so a failure never reads as an empty queue. It logs in with your SSH keys (BatchMode, the island's own ssh options), runs only `squeue`, and needs no permissions.
