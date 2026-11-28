"""Small SCM host for the GeoRoute WARP controller; no executable wrapper."""
import ctypes
import threading


def run_service(name, factory, log):
    from ctypes import wintypes as w
    api = ctypes.WinDLL('advapi32', use_last_error=True)
    main_type = ctypes.WINFUNCTYPE(None, w.DWORD, ctypes.POINTER(w.LPWSTR))
    handler_type = ctypes.WINFUNCTYPE(w.DWORD, w.DWORD, w.DWORD, w.LPVOID, w.LPVOID)

    class Status(ctypes.Structure):
        _fields_ = [(key, w.DWORD) for key in ('type', 'state', 'controls', 'error', 'specific', 'checkpoint', 'hint')]

    class Entry(ctypes.Structure):
        _fields_ = [('name', w.LPWSTR), ('main', main_type)]

    api.RegisterServiceCtrlHandlerExW.argtypes = [w.LPCWSTR, handler_type, w.LPVOID]
    api.RegisterServiceCtrlHandlerExW.restype = w.HANDLE
    api.SetServiceStatus.argtypes = [w.HANDLE, ctypes.POINTER(Status)]
    api.SetServiceStatus.restype = w.BOOL
    api.StartServiceCtrlDispatcherW.argtypes = [ctypes.POINTER(Entry)]
    api.StartServiceCtrlDispatcherW.restype = w.BOOL
    status, lock = Status(type=0x10), threading.Lock()
    handle, worker, error = None, None, 0
    stopping = threading.Event()

    def report(state, code=0):
        with lock:
            status.state, status.error = state, code
            status.controls = 0x105 if state == 4 else 0  # STOP, SHUTDOWN, PRESHUTDOWN
            status.checkpoint = status.checkpoint + 1 if state in (2, 3) else 0
            status.hint = 30000 if state in (2, 3) else 0
            if not api.SetServiceStatus(handle, ctypes.byref(status)):
                raise ctypes.WinError(ctypes.get_last_error())

    @handler_type
    def control(code, event_type, event_data, context):
        try:
            if code in (1, 5, 15):
                stopping.set()
                report(3)
                if worker:
                    worker.stop.set()
            elif code == 4:
                report(status.state)
            elif code in (128, 129, 130, 131, 132) and worker:
                worker.enqueue(code)
            elif code >= 128:
                return 120
        except Exception as exc:
            log('Service control: ' + type(exc).__name__)
            return 1067
        return 0

    @main_type
    def service_main(argc, argv):
        nonlocal handle, worker, error
        handle = api.RegisterServiceCtrlHandlerExW(name, control, None)
        if not handle:
            error = ctypes.get_last_error()
            return
        try:
            report(2)
            worker = factory()
            if stopping.is_set():
                worker.stop.set()
            worker.start(on_ready=lambda: report(4) if not stopping.is_set() else None)
            if not stopping.is_set():
                raise RuntimeError('Controller exited unexpectedly')
        except Exception as exc:
            error = 1067
            log('Service worker: ' + type(exc).__name__)
        finally:
            if worker:
                worker.close()
            report(1, error)

    table = (Entry * 2)(Entry(name, service_main), Entry(None, main_type()))
    if not api.StartServiceCtrlDispatcherW(table):
        raise ctypes.WinError(ctypes.get_last_error())
    return error
