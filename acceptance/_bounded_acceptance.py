"""Absolute acceptance-worker deadline and persistent failure diagnostics."""
from __future__ import annotations
import json,os,runpy,secrets,signal,subprocess,sys,sysconfig,tempfile,time
from pathlib import Path

class _WindowsJob:
    """Own descendants after parent exit without enumerating unrelated processes."""
    def __init__(self):
        import ctypes
        from ctypes import wintypes as w
        class Basic(ctypes.Structure):
            _fields_=[('process_time',ctypes.c_longlong),('job_time',ctypes.c_longlong),('flags',w.DWORD),
                      ('min_ws',ctypes.c_size_t),('max_ws',ctypes.c_size_t),('active',w.DWORD),
                      ('affinity',ctypes.c_size_t),('priority',w.DWORD),('scheduling',w.DWORD)]
        class IO(ctypes.Structure):
            _fields_=[(name,ctypes.c_ulonglong) for name in ('read_ops','write_ops','other_ops','read_bytes','write_bytes','other_bytes')]
        class Extended(ctypes.Structure):
            _fields_=[('basic',Basic),('io',IO),('process_memory',ctypes.c_size_t),('job_memory',ctypes.c_size_t),
                      ('peak_process',ctypes.c_size_t),('peak_job',ctypes.c_size_t)]
        self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes=[ctypes.c_void_p,w.LPCWSTR];self.kernel.CreateJobObjectW.restype=w.HANDLE
        self.kernel.SetInformationJobObject.argtypes=[w.HANDLE,ctypes.c_int,ctypes.c_void_p,w.DWORD];self.kernel.SetInformationJobObject.restype=w.BOOL
        self.kernel.AssignProcessToJobObject.argtypes=[w.HANDLE,w.HANDLE];self.kernel.AssignProcessToJobObject.restype=w.BOOL
        self.kernel.CloseHandle.argtypes=[w.HANDLE];self.kernel.CloseHandle.restype=w.BOOL
        self.handle=self.kernel.CreateJobObjectW(None,None)
        if not self.handle:raise ctypes.WinError(ctypes.get_last_error())
        limits=Extended();limits.basic.flags=0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle,9,ctypes.byref(limits),ctypes.sizeof(limits)):
            error=ctypes.WinError(ctypes.get_last_error());self.close();raise error
    def assign(self,process):
        import ctypes
        if not self.kernel.AssignProcessToJobObject(self.handle,int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
    def close(self):
        if self.handle:
            import ctypes
            if not self.kernel.CloseHandle(self.handle):raise ctypes.WinError(ctypes.get_last_error())
            self.handle=None

def stop_tree(process: subprocess.Popen) -> None:
    """Stop a known API subprocess; the outer job owns its crash path."""
    if process.poll() is not None:return
    if os.name=='nt':
        subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW,timeout=10)
    else:process.kill()
    process.wait(timeout=10)

def supervise(script: Path,arguments: list[str],*,timeout_seconds: float,report_path: Path) -> int:
    if not 0<timeout_seconds<=120:raise ValueError('Acceptance deadline must be in (0, 120] seconds')
    started=time.monotonic();report_path=report_path.resolve()
    owned=tempfile.TemporaryDirectory(prefix='echo-acceptance-worker-')
    process=None;job=None;output='';code=125;outcome='runner_error';errors=[]
    try:
        env=os.environ.copy()
        for key in list(env):
            if any(part in key.upper() for part in ('API_KEY','ASR_SECRET','MODEL_BASE_URL','EMBEDDING_BASE_URL','OPENAI_BASE_URL')):
                env.pop(key,None)
        env.pop('RESOURCE_EMBEDDING_URL',None)
        env.update(TEMP=owned.name,TMP=owned.name,DATABASE_URL='sqlite:///'+(Path(owned.name)/'import-only.db').as_posix(),
                   AUTH_SECRET=secrets.token_urlsafe(32),DEMO_MODE='1',APP_ENV='development',
                   PYTHONUNBUFFERED='1',PYTHONDONTWRITEBYTECODE='1',PYTHONUTF8='1')
        env['PYTHONPATH']=os.pathsep.join(filter(None,(sysconfig.get_path('purelib'),env.get('PYTHONPATH'))))
        if os.name=='nt':job=_WindowsJob()
        # A venv launcher may spawn before assignment: use the base executable.
        # This bootstrap cannot run target code before the job owns it.
        command=[getattr(sys,'_base_executable',sys.executable),'-u',str(Path(__file__).resolve()),'--bootstrap',str(script.resolve()),*arguments]
        process=subprocess.Popen(command,cwd=script.resolve().parent.parent,env=env,stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0,start_new_session=os.name!='nt')
        if job:job.assign(process)
        remaining=timeout_seconds-(time.monotonic()-started)
        if remaining<=0:raise subprocess.TimeoutExpired(command,timeout_seconds)
        output,_=process.communicate(input='go\n',timeout=remaining)
        code=process.returncode;outcome='passed' if code==0 else 'failed'
    except subprocess.TimeoutExpired as exc:
        output=exc.output or ''
        if isinstance(output,bytes):output=output.decode('utf-8',errors='replace')
        code=124;outcome='timed_out'
    except Exception as exc:errors.append(type(exc).__name__+': '+str(exc))
    finally:
        try:
            if job:job.close()
            elif process and os.name!='nt':
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
            elif process:stop_tree(process)
        except Exception as exc:errors.append('termination: '+repr(exc))
        if process:
            try:
                drained,_=process.communicate(timeout=5)
                if drained is not None:output=drained
            except Exception as exc:errors.append('output drain: '+repr(exc))
        try:owned.cleanup()
        except Exception as exc:errors.append('temporary cleanup: '+repr(exc))
        if errors and code==0:code=125;outcome='runner_error'
        result={'runner':script.name,'outcome':outcome,'exit_code':code,
                'worker_exit_code':process.returncode if process else None,
                'deadline_seconds':timeout_seconds,'elapsed_seconds':round(time.monotonic()-started,3),
                'output_tail':output[-12000:],'cleanup_or_runner_errors':errors,
                'synthetic_database_only':True,'provider_credentials_stripped':True}
        report_path.parent.mkdir(parents=True,exist_ok=True)
        report_path.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(output,end='')
    print(f'Acceptance {outcome}; deadline={timeout_seconds}s; elapsed={result["elapsed_seconds"]}s; report={report_path}',flush=True)
    return code

if __name__=='__main__':
    if len(sys.argv)<3 or sys.argv[1]!='--bootstrap' or sys.stdin.readline()!='go\n':raise SystemExit(125)
    target=Path(sys.argv[2]);sys.argv=sys.argv[2:];sys.path.insert(0,str(target.parent))
    runpy.run_path(str(target),run_name='__main__')
