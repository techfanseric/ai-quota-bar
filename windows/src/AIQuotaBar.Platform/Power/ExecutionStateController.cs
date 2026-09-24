// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：IOPMAssertionCreateWithName → SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)，零权限）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Power/ExecutionStateControllerTests.cs
//
// P/Invoke 依据（Microsoft Learn，winbase.h）：
// EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags)（kernel32.dll）；
// 成功返回线程先前的 execution state，失败返回 NULL(0)。本函数不设置 last error。
// ES_CONTINUOUS = 0x80000000，ES_SYSTEM_REQUIRED = 0x00000001，ES_DISPLAY_REQUIRED = 0x00000002。
// 清除方式：再次调用 SetThreadExecutionState(ES_CONTINUOUS)（不带需求位）。

#nullable enable

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AIQuotaBar.Platform.Power;

/// <summary>
/// 「任务进行中防止系统睡眠与显示器关闭」控制器：kernel32 SetThreadExecutionState 的安全封装。
/// </summary>
/// <remarks>
/// macOS 端对应物：IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep / PreventDisplaySleep)。
/// Windows 上无需任何权限（计划 §5.1：这是 macOS 版主路径的对应物；合盖模式 v1 不做）。
///
/// 线程亲和性（重要）：execution state 是**每线程**属性——开启与清除必须在同一线程调用。
/// 本类在首次状态变更时钉住线程 ID，跨线程调用抛 <see cref="InvalidOperationException"/>；
/// Dispose 同样受此约束（在其他线程静默"清除"只会清掉那个线程自己的标志，原线程仍保持
/// 阻止睡眠状态——宁可抛错也不假成功）。App 层应把控制器生命周期绑定到固定线程（主/UI 线程）。
/// </remarks>
public sealed class ExecutionStateController : IDisposable
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsDisplayRequired = 0x00000002;

    private readonly object _gate = new();
    private int _ownerThreadId;      // 0 = 尚未钉线程（从未开启过）
    private bool _keepAwakeActive;
    private bool _disposed;

    /// <summary>当前是否处于「阻止系统 + 显示器空闲休眠」状态（本类追踪的应用层状态机）。</summary>
    public bool IsKeepAwakeActive
    {
        get
        {
            lock (_gate)
            {
                return _keepAwakeActive;
            }
        }
    }

    /// <summary>
    /// 开启持续阻止：ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED。
    /// 已开启时重复调用为无害幂等操作。
    /// </summary>
    /// <exception cref="ObjectDisposedException">实例已释放。</exception>
    /// <exception cref="InvalidOperationException">跨线程调用（须与开启线程一致）。</exception>
    /// <exception cref="Win32Exception">SetThreadExecutionState 返回 0（失败）。</exception>
    public void PreventSystemAndDisplaySleep()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            EnsureOwnerThread();
            if (_keepAwakeActive)
            {
                return; // 幂等：连续开启无累积语义
            }

            ApplyState(EsContinuous | EsSystemRequired | EsDisplayRequired);
            _keepAwakeActive = true;
        }
    }

    /// <summary>
    /// 清除阻止：SetThreadExecutionState(ES_CONTINUOUS)，恢复系统默认空闲策略。
    /// 未开启时调用为无害幂等操作。
    /// </summary>
    /// <exception cref="ObjectDisposedException">实例已释放。</exception>
    /// <exception cref="InvalidOperationException">跨线程调用（须与开启线程一致）。</exception>
    /// <exception cref="Win32Exception">SetThreadExecutionState 返回 0（失败）。</exception>
    public void RestoreDefault()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            EnsureOwnerThread();
            if (!_keepAwakeActive)
            {
                return; // 幂等：本就处于默认状态
            }

            ApplyState(EsContinuous);
            _keepAwakeActive = false;
        }
    }

    /// <summary>
    /// 释放实例：若仍处于阻止状态则先 RestoreDefault（同样要求在钉住线程上调用）。
    /// 重复 Dispose 安全。
    /// </summary>
    /// <exception cref="InvalidOperationException">仍处于阻止状态却从其他线程 Dispose。</exception>
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            if (_keepAwakeActive)
            {
                EnsureOwnerThread(); // 不静默跳过：见类注释
                ApplyState(EsContinuous);
                _keepAwakeActive = false;
            }

            _disposed = true;
        }
    }

    private void ApplyState(uint flags)
    {
        var previous = NativeMethods.SetThreadExecutionState(flags);
        if (previous == 0)
        {
            // 文档口径：返回 NULL 即失败（成功时返回先前状态）。
            // 注：先前状态理论上可能恰为 0，但那同样意味着本调用前线程无持续标志，视作失败是保守且安全的。
            throw new Win32Exception("SetThreadExecutionState 失败（返回 0）。");
        }
    }

    private void EnsureOwnerThread()
    {
        var currentThreadId = Environment.CurrentManagedThreadId;
        if (_ownerThreadId == 0)
        {
            _ownerThreadId = currentThreadId; // 首次状态变更：钉线程
        }
        else if (_ownerThreadId != currentThreadId)
        {
            throw new InvalidOperationException(
                $"ExecutionStateController 必须在同一线程开/关（钉住线程 {_ownerThreadId}，实然线程 {currentThreadId}）。" +
                "execution state 是每线程属性，跨线程清除不会生效。");
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(ExecutionStateController));
        }
    }

    /// <summary>kernel32 原生入口（签名按 winbase.h 核对：参数与返回值均为 EXECUTION_STATE/DWORD）。</summary>
    private static class NativeMethods
    {
        [DllImport("kernel32.dll", EntryPoint = "SetThreadExecutionState")]
        public static extern uint SetThreadExecutionState(uint esFlags);
    }
}
