// Swift 来源：无（Windows 端新增；远程物理机 §10.4 的完整控制入口）。
// 用途：SSH / 桌面会话下的环境诊断（env/doctor）、自检（selftest）、凭据库操作（cred）、
// provider 配额直查（glm/minimax）、Clash 控制（clash）。全部操作带文件日志（见 CliLog）。
//
// 退出码约定：0 = 成功；1 = 操作失败（网络/凭据/断言等）；2 = 用法错误（参数缺失/未知命令）。

using AIQuotaBar.Cli;

var exitCode = await ProgramRunner.RunAsync(args).ConfigureAwait(false);
return exitCode;
