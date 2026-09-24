// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：macOS 单实例机制（NSApp activate / 分布式通知）→ named mutex + named event 激活）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/SingleInstance/AppMutexTests.cs
//
// 机制说明（Microsoft Learn，同步对象）：
// - named mutex（"Local\..." 前缀 = 同一登录会话可见；"Global\..." 为全系统。托盘应用单实例用 Local 足够，
//   且避免多用户/服务会话下的意外跨会话冲突）。
// - mutex 具有线程所有权：同线程重复 WaitOne 会成功（递归获得），因此「二次启动探测」的语义由
//   另一个进程承担；本类对同进程重复 TryAcquire 仅作幂等处理（见注释）。
// - WaitOne(TimeSpan.Zero) 非阻塞尝试；上一持有进程崩溃未释放时抛 AbandonedMutexException，
//   此时所有权已被授予本调用方——按「获得」处理（接管单实例角色）。
// - 二次启动信号用 named EventWaitHandle（AutoReset）：第二实例 Set 后即退出，
//   首实例在自有线程上等待该事件并激活主窗口（App 层接手，计划 §4「单实例」行）。

#nullable enable

using System;
using System.Threading;

namespace AIQuotaBar.Platform.SingleInstance;

/// <summary>
/// 单实例守卫：named mutex 探测 + named event 的「二次启动」信号通道。
/// </summary>
/// <remarks>
/// 命名约定（<paramref name="applicationName"/> 须为不含 <c>'\'</c> 的应用标识，如 <c>"AIQuotaBar"</c>）：
/// mutex = <c>Local\{applicationName}.AppMutex</c>；事件 = <c>Local\{applicationName}.SecondInstanceSignal</c>。
///
/// 典型用法：首实例 <see cref="TryAcquire"/> 成功后监听 <see cref="SecondInstanceSignal"/>；
/// 后续实例 <see cref="TryAcquire"/> 失败 → <see cref="SignalSecondInstance"/> → 退出。
/// 线程注意：mutex 的获取与释放具有线程所有权，真实使用中应固定在同一（主）线程操作本实例。
/// </remarks>
public sealed class AppMutex : IDisposable
{
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _secondInstanceSignal;
    private int _ownerThreadId;   // 获得所有权的线程（0 = 尚未获得；TryAcquire 成功时记录，构造线程无关）
    private bool _acquired;
    private bool _disposed;

    /// <param name="applicationName">应用标识（非空，不含 <c>'\'</c>），参与两个内核对象命名。</param>
    /// <exception cref="ArgumentException"><paramref name="applicationName"/> 非法。</exception>
    public AppMutex(string applicationName)
    {
        if (string.IsNullOrEmpty(applicationName))
        {
            throw new ArgumentException("应用名不可为空。", nameof(applicationName));
        }

        if (applicationName.Contains('\\'))
        {
            throw new ArgumentException($"应用名不可包含 '\\'（实然：\"{applicationName}\"）。", nameof(applicationName));
        }

        _mutex = new Mutex(initiallyOwned: false, name: $@"Local\{applicationName}.AppMutex");
        _secondInstanceSignal = new EventWaitHandle(
            initialState: false,
            mode: EventResetMode.AutoReset,
            name: $@"Local\{applicationName}.SecondInstanceSignal",
            createdNew: out _);
    }

    /// <summary>本实例当前是否持有单实例 mutex。</summary>
    public bool IsAcquired => _acquired;

    /// <summary>
    /// 「二次启动」信号句柄：首实例在任意自有线程上等待它，收到即激活主窗口（UI 阶段接线）。
    /// AutoReset 语义：每次 WaitOne 消费一次信号，逐次响应对应每个后续启动尝试。
    /// </summary>
    public EventWaitHandle SecondInstanceSignal => _secondInstanceSignal;

    /// <summary>
    /// 非阻塞尝试获得单实例 mutex。
    /// </summary>
    /// <remarks>
    /// 已获得时重复调用幂等返回 <see langword="true"/>（注意：受 mutex 线程所有权影响，
    /// 同线程再次 WaitOne 也会成功——单实例语义由跨进程探测保证，本方法不做同进程区分）。
    /// 前一持有进程崩溃遗留的弃用 mutex 会被接管（AbandonedMutexException 分支）。
    /// 获得成功时把所有权线程记录为**实际执行获得的线程**（构造线程可能不同），
    /// 供 <see cref="Release"/> / <see cref="Dispose"/> 的线程校验使用。
    /// </remarks>
    public bool TryAcquire()
    {
        ThrowIfDisposed();
        if (_acquired)
        {
            return true;
        }

        try
        {
            _acquired = _mutex.WaitOne(TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            // 弃用例外发生时所有权已授予本线程：接管成功
            _acquired = true;
        }

        if (_acquired)
        {
            // 所有权线程 = 实际获得线程，而非构造线程
            _ownerThreadId = Environment.CurrentManagedThreadId;
        }

        return _acquired;
    }

    /// <summary>
    /// 释放单实例 mutex（须由获得它的同一线程调用；真实使用中即首实例主线程）。
    /// 未获得时调用为无害幂等操作。
    /// </summary>
    /// <remarks>
    /// 与 <see cref="Dispose"/> 一致地容忍所有权丢失（如弃用后被其他实例接管并释放）：
    /// 此时原生 ReleaseMutex 抛 <see cref="ApplicationException"/>，本方法按「已释放」静默完成。
    /// </remarks>
    /// <exception cref="InvalidOperationException">由非获得线程调用（mutex 线程所有权）。</exception>
    public void Release()
    {
        ThrowIfDisposed();
        if (!_acquired)
        {
            return;
        }

        if (Environment.CurrentManagedThreadId != _ownerThreadId)
        {
            throw new InvalidOperationException(
                $"Release 须在获得 mutex 的线程调用（获得线程 {_ownerThreadId}，实然线程 {Environment.CurrentManagedThreadId}）。");
        }

        try
        {
            _mutex.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // 所有权已不在本线程/本句柄（弃用后被接管释放等）：视为已释放，与 Dispose 行为一致
        }

        _acquired = false;
    }

    /// <summary>
    /// 发出「二次启动」信号（供后续启动的实例调用；与是否获得 mutex 无关）。
    /// </summary>
    public void SignalSecondInstance()
    {
        ThrowIfDisposed();
        _secondInstanceSignal.Set();
    }

    /// <summary>
    /// 关闭两个内核对象句柄。若本实例仍持有 mutex：在获得线程上调用则先行释放；
    /// 跨线程时不强行释放（直接关闭句柄会让内核对象弃用，下一实例经
    /// <see cref="TryAcquire"/> 的弃用接管分支恢复单实例语义，不产生悬挂）。
    /// 重复 Dispose 安全。
    /// </summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (_acquired && Environment.CurrentManagedThreadId == _ownerThreadId)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // 所有权已不在本句柄（如弃用后被其他实例接管并释放）：
                // 句柄即将关闭，无需也无法强求释放——吞掉是正确行为。
            }

            _acquired = false;
        }

        _mutex.Dispose();
        _secondInstanceSignal.Dispose();
        _disposed = true;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(AppMutex));
        }
    }
}
