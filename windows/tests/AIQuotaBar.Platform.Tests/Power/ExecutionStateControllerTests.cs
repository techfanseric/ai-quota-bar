// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOPMAssertionCreateWithName → SetThreadExecutionState）
// 被测类型：AIQuotaBar.Platform/Power/ExecutionStateController.cs
// 原则（任务书）：不断言真实系统电源副作用，只断言控制器状态机、返回值语义与异常路径。
// 线程亲和性用专用 Thread + Join 验证（不引入 async 等待辅助）。

using System;
using System.Threading;
using AIQuotaBar.Platform.Power;
using Xunit;

namespace AIQuotaBar.Platform.Tests.Power;

[Trait("Category", "RequiresWindows")]
public sealed class ExecutionStateControllerTests
{
    [Fact]
    public void PreventThenRestore_TogglesStateWithoutError()
    {
        using var controller = new ExecutionStateController();

        controller.PreventSystemAndDisplaySleep();
        Assert.True(controller.IsKeepAwakeActive, "开启后状态机应为阻止睡眠。");

        controller.RestoreDefault();
        Assert.False(controller.IsKeepAwakeActive, "恢复后状态机应回到默认。");
    }

    [Fact]
    public void Prevent_WhenAlreadyActive_IsIdempotent()
    {
        using var controller = new ExecutionStateController();
        controller.PreventSystemAndDisplaySleep();

        controller.PreventSystemAndDisplaySleep(); // 应无异常、状态不变

        Assert.True(controller.IsKeepAwakeActive, "重复开启应保持阻止状态（幂等）。");
    }

    [Fact]
    public void RestoreDefault_WhenInactive_IsNoOp()
    {
        using var controller = new ExecutionStateController();

        controller.RestoreDefault(); // 未开启即恢复：应无异常

        Assert.False(controller.IsKeepAwakeActive, "未开启时恢复不应翻转状态。");
    }

    [Fact]
    public void Prevent_FromDifferentThread_Throws()
    {
        var controller = new ExecutionStateController();
        controller.PreventSystemAndDisplaySleep(); // 钉在测试线程

        var caught = RunOnSeparateThread(controller.PreventSystemAndDisplaySleep);

        // 应然：跨线程调用抛 InvalidOperationException（实然：静默成功为失败——清除不会生效于原线程）。
        Assert.True(caught is InvalidOperationException,
            $"跨线程开启应抛 InvalidOperationException（实然：{caught?.GetType().FullName ?? "无异常"}）。");

        controller.Dispose(); // 回到钉住线程清理，避免测试线程残留 keep-awake 标志
    }

    [Fact]
    public void Dispose_WhenActive_RestoresState_AndIsIdempotent()
    {
        var controller = new ExecutionStateController();
        controller.PreventSystemAndDisplaySleep();

        controller.Dispose();
        controller.Dispose(); // 重复 Dispose 安全

        Assert.False(controller.IsKeepAwakeActive, "释放时应先清除阻止状态。");
    }

    [Fact]
    public void Dispose_FromWrongThread_Throws()
    {
        var controller = new ExecutionStateController();
        controller.PreventSystemAndDisplaySleep();

        var caught = RunOnSeparateThread(controller.Dispose);

        Assert.True(caught is InvalidOperationException,
            $"仍处阻止状态时跨线程 Dispose 应抛 InvalidOperationException（实然：{caught?.GetType().FullName ?? "无异常"}）。");

        controller.Dispose(); // 回到钉住线程清理，避免测试残留
    }

    [Fact]
    public void UseAfterDispose_Throws()
    {
        var controller = new ExecutionStateController();
        controller.Dispose();

        Assert.Throws<ObjectDisposedException>(controller.PreventSystemAndDisplaySleep);
        Assert.Throws<ObjectDisposedException>(controller.RestoreDefault);
    }

    /// <summary>在专用线程上执行 action 并等待结束，返回抛出的异常（无异常则 null）。</summary>
    private static Exception? RunOnSeparateThread(Action action)
    {
        Exception? caught = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                caught = ex;
            }
        });
        thread.Start();
        thread.Join();
        return caught;
    }
}
