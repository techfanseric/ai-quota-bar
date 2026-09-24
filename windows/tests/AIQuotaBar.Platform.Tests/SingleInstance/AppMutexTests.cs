// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：macOS 单实例/激活 → named mutex + named event）
// 被测类型：AIQuotaBar.Platform/SingleInstance/AppMutex.cs
// 注意：named mutex 具线程所有权——同线程对同一内核对象再次 WaitOne 会递归成功，
// 因此「第二实例」的探测在专用线程上执行（真实场景中第二实例是另一进程，天然异线程）。

using System;
using System.Threading;
using AIQuotaBar.Platform.SingleInstance;
using Xunit;

namespace AIQuotaBar.Platform.Tests.SingleInstance;

[Trait("Category", "RequiresWindows")]
public sealed class AppMutexTests
{
    [Fact]
    public void TryAcquire_OnFreshName_Succeeds()
    {
        var name = NewName();
        using var first = new AppMutex(name);

        var acquired = first.TryAcquire();

        Assert.True(acquired, "全新名称的首个实例应获得 mutex。");
        Assert.True(first.IsAcquired, "获得后 IsAcquired 应为 true。");
    }

    [Fact]
    public void TryAcquire_IsIdempotent_OnSameInstance()
    {
        using var first = new AppMutex(NewName());
        first.TryAcquire();

        Assert.True(first.TryAcquire(), "同实例重复 TryAcquire 应幂等返回 true。");
    }

    [Fact]
    public void TryAcquire_FromSecondInstanceOnOtherThread_Fails()
    {
        var name = NewName();
        using var first = new AppMutex(name);
        Assert.True(first.TryAcquire());
        using var second = new AppMutex(name);

        // 第二实例在异线程探测（模拟另一进程）：应失败。
        var acquiredOnOtherThread = RunOnSeparateThread(second.TryAcquire);

        Assert.False(acquiredOnOtherThread, "已存在的单实例应使后续实例 TryAcquire 失败。");
        Assert.False(second.IsAcquired, "失败后第二实例不应标记为获得。");
    }

    [Fact]
    public void SecondInstanceSignal_CrossesInstances()
    {
        var name = NewName();
        using var first = new AppMutex(name);
        Assert.True(first.TryAcquire());
        using var second = new AppMutex(name);
        Assert.False(RunOnSeparateThread(second.TryAcquire));

        second.SignalSecondInstance(); // 第二实例发出激活信号后即退出

        // 首实例在自己的事件上观察到信号（WaitOne(0) 非阻塞探测；AutoReset 消费信号）。
        Assert.True(first.SecondInstanceSignal.WaitOne(0), "首实例应收到二次启动信号。");
    }

    [Fact]
    public void Release_AllowsNextInstanceToAcquire()
    {
        var name = NewName();
        using var first = new AppMutex(name);
        Assert.True(first.TryAcquire());
        first.Release(); // 同线程释放：合法

        using var second = new AppMutex(name);
        Assert.True(second.TryAcquire(), "释放后下一实例应能获得单实例角色。");
        second.Release();
    }

    [Fact]
    public void TryAcquire_TakesOverAbandonedMutex()
    {
        // 前持有线程未释放即终止 → mutex 弃用 → 后续实例应接管（AbandonedMutexException 分支）。
        var name = NewName();
        var first = new AppMutex(name);
        var acquiredInThread = new ManualResetEventSlim(false);
        var owner = new Thread(() =>
        {
            first.TryAcquire();
            acquiredInThread.Set();
            // 线程随即结束：不 Release，制造弃用
        });
        owner.Start();
        acquiredInThread.Wait();
        owner.Join();

        using var second = new AppMutex(name);

        // 应然：接管弃用 mutex 成功（实然：AbandonedMutexException 逃逸或 false 即失败）。
        Assert.True(second.TryAcquire(), "弃用 mutex 应被后续实例接管。");
        second.Release();
        first.Dispose(); // 已被接管释放：Dispose 内部容忍所有权丢失
    }

    [Fact]
    public void Release_FromWrongThread_Throws()
    {
        using var first = new AppMutex(NewName());
        Assert.True(first.TryAcquire());

        var caught = RunOnSeparateThreadCatching(() => first.Release());

        Assert.True(caught is InvalidOperationException,
            $"跨线程 Release 应抛 InvalidOperationException（实然：{caught?.GetType().FullName ?? "无异常"}）。");
    }

    [Fact]
    public void Ctor_InvalidName_Throws()
    {
        Assert.Throws<ArgumentException>(() => new AppMutex(string.Empty));
        Assert.Throws<ArgumentException>(() => new AppMutex("bad\\name"));
    }

    private static string NewName() => $"AIQuotaBar.Test.{Guid.NewGuid():N}";

    /// <summary>在专用线程上执行并等待结束，返回布尔结果（异线程 mutex 探测）。</summary>
    private static bool RunOnSeparateThread(Func<bool> action)
    {
        bool result = false;
        Exception? caught = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = action();
            }
            catch (Exception ex)
            {
                caught = ex;
            }
        });
        thread.Start();
        thread.Join();

        if (caught is not null)
        {
            throw caught; // 测试线程上如实暴露异线程异常
        }

        return result;
    }

    /// <summary>在专用线程上执行并等待结束，返回抛出的异常（无异常则 null）。</summary>
    private static Exception? RunOnSeparateThreadCatching(Action action)
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
