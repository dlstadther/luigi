# Proposal: Faster, deterministic tests for Luigi (local and CI)

| | |
|---|---|
| **Status** | Draft for maintainer review |
| **Date** | 2026-11-26 |
| **Scope** | `test/`, `tox.ini`, `pyproject.toml` (test deps), `.github/workflows/pythonbuild.yml`, `scripts/ci/` |
| **Non-goals** | 100% coverage in CI; rewriting the suite; a 5-minute end-to-end CI for every integration |

---

## 1. Summary

Slow and flaky tests make Luigi hard to maintain and PRs hard to review. I measured
the suite instead of guessing. The pain comes from a small number of fixable causes,
not from the size of the suite:

1. **About 92% of serial `core` time is spent in 47 tests (3% of the suite)**, and most of
   that time is `sleep()`: retry back-offs, fixed "wait for server" sleeps, and tasks that
   sleep so another thread has time to act.
2. **One config default costs 4 minutes locally.** `RemoteScheduler` retries now go through
   tenacity with `rpc-retry-wait = 30` s. The test hack that used to turn waits off
   (`self.sch._wait = lambda: None`, `test/server_test.py:296`) no longer does anything.
   Each of the four `test_404` tests sleeps 2 × 30 s. One line in the test config takes
   `server_test.py` from **244 s to 3.4 s**.
3. **Coverage doubles CI time.** `coverage<6` is pinned. On current Pythons it falls back to
   its pure-Python tracer: **92 s → 48 s** for `core` when moved to coverage 7 with
   `COVERAGE_CORE=sysmon`, with identical results.
4. **The confirmed flakes have three known causes** (Luo et al. 2014: async-wait,
   concurrency, order dependency):
   - two test files start a real `luigid` on the **same hard-coded port 8082**, and xdist
     can run them at the same time;
   - "is the server up yet" is checked with `sleep(0.1)` / `sleep(0.5)`;
   - assertions check wall-clock time (`assertLess(duration, 4)`);
   - task-registry state leaks between tests that share an xdist worker.
5. **Some tests are hidden instead of fixed.** 23 tests are skipped on CI with
   `skipOnTravisAndGithubActions`, most pointing at dead 2015 Travis job URLs. When I
   un-skipped them, **14 failed every time: they are broken, not flaky.** One class makes
   real calls to AWS. As a result, CI and local runs execute different suites.
6. **The CI matrix has 34 jobs per PR**, and 28 of them run only 12–25 s of tests each.
   On top of that, `codecov` upload failures fail the build (`fail_ci_if_error: true` in
   every job), CI has no job timeouts, and new pushes don't cancel the previous run.

The proposal has four phases. Phase 0 is a handful of small PRs that roughly halve
`core` CI time and cut local `core` time by 2–8×. Phase 1 removes the known sources of
flakiness. Phase 2 restructures CI from 34 jobs to about 12 per PR, with a full nightly
matrix. Phase 3 is ongoing hygiene that keeps the suite fast.

---

## 2. Method

All numbers were measured on a 4-vCPU Linux container (similar to a GitHub
`ubuntu-22.04` runner, which has 4 vCPUs), Python 3.13, at commit `0ef6a79` (v3.8.0). The
fork has no GitHub Actions history, so CI job durations are inferred from local runs
plus spotify/luigi#3398 ("core takes about 5 minutes and others take about 1 minute or
less" before xdist; 2–4 min after).

| Experiment | What it shows |
|---|---|
| `core` serial with `--durations` and junit XML | per-test and per-file cost |
| `core` CI-like (`-n auto --dist=loadfile`, coverage on/off, `GITHUB_ACTIONS=true`) | real CI cost and the coverage overhead |
| Same with coverage 7 (`ctrace`, `sysmon`) | how much a tracer upgrade saves |
| `core` 6× (3× at `-n 4`, 3× at `-n 12` oversubscribed) | flakiness in the suite CI actually runs |
| CI-skipped and timing-sensitive files, 10× (5 idle, 5 with 8 busy-loop processes) | whether hidden tests are flaky or broken |
| `contrib`, `aws`, `apache`, `scheduler` envs | per-env cost |
| Cold vs. warm `uv sync` (new cache) on 3.10 and 3.13 | whether dependency install is a bottleneck |

Reproduction commands are in [Appendix A](#appendix-a-reproduction).

---

## 3. Findings

### 3.1 Where the time goes

**`core`, serial, no CI skips (what a contributor gets when running the suite locally):**
391 s, 27 failures.

| File | Serial time | Tests | Main cause |
|---|---:|---:|---|
| `server_test.py` | **244.0 s** | 59 | 4 × `test_404` at 60.1 s each = RPC retry back-off (2 × 30 s) |
| `worker_test.py` | 34.9 s | 107 | tasks that `sleep(1..5)`, worker wait intervals, real DNS lookup of `tld.invalid` |
| `worker_scheduler_com_test.py` | 18.1 s | 5 | tasks sleep 3 s; test does `t.join(1)` / `t.join(3)` then asserts |
| `mypy_test.py` | 13.9 s | 5 | runs mypy (actual work, but cacheable or markable as slow) |
| `rpc_test.py` | 13.2 s | 208 | 4 tests × 2 s of retry waits (`_rpc_retry_wait = 1`) |
| `scheduler_test.py` | 12.3 s | 22 | `StableDoneCooldownSecsTest`: real `luigid` on :8082 plus sleeps |
| `task_running_resources_test.py` | 11.2 s | 3 | real `luigid` on :8082, `sleep(0.5)` startup, wall-clock assertions |
| `custom_metrics_test.py` | 6.0 s | 1 | `time.sleep(n)` in task |
| everything else | ~37 s | ~1,300 | |

- **47 tests that take ≥1 s each account for 358 s of the 387 s (92%).**
- Without `server_test.py` (most of which is skipped on CI), the remaining ~143 s is
  still mostly sleeps. `scheduler_api_test.py` has 196 tests and needs only 4.1 s;
  `parameter_test.py` has 160 and needs 3.2 s. Fast tests are the norm here.

**`core`, CI-like (`-n auto --dist=loadfile`, `GITHUB_ACTIONS=true`):**

| Configuration | Wall time |
|---|---:|
| Current (`coverage==5.5`, pure-Python tracer) | **92 s** |
| No coverage | 46 s |
| `coverage 7.x`, `COVERAGE_CORE=ctrace` | 57 s |
| `coverage 7.x`, `COVERAGE_CORE=sysmon` (PEP 669, Python ≥3.12) | **48 s** |
| `--dist=worksteal` instead of `loadfile` | 52 s (no gain) |

`coverage 5.5` has no compiled tracer for the Pythons Luigi supports today
(`coverage.collector.CTracer is None` on 3.13), so every line runs through a Python-level
trace function. `.coveragerc` also uses `concurrency=multiprocessing` with
`COVERAGE_PROCESS_START`, which adds the same tracer to every child process. Luigi starts
child processes constantly: workers, `luigid`, task processes.

**Other envs** (CI-like, coverage on):

| Env | Test time |
|---|---:|
| `contrib` | 12 s |
| `aws` | 25 s (10.7 s of it is `test_remove_dir_batch`) |
| `apache` | 13 s |
| `scheduler` (not in CI) | 22 s |

**Dependency install is not a bottleneck.** A cold `uv sync --group common` with an empty
cache took 4 s on 3.13 and 6 s on 3.10, and that includes building the sdist-only pins
(psutil 3.4.2, pymongo 3.4.0, SQLAlchemy 1.3.24). Per-job overhead in CI therefore comes
from runner start-up, installing tox, the Python download, `docker pull` for Azurite,
MySQL init, and the Codecov upload. These are fixed costs per job, so the number of jobs
matters more than how fast each one is.

**Collection** takes about 4 s per xdist worker, which is acceptable.

### 3.2 Flakiness: what I could reproduce, and why

The `core` suite that CI runs, with CI skips active, was **deterministic in 6 of 6 runs**,
including runs at 3× CPU oversubscription. The only two failures appeared every time and
come from this sandbox: `ssh` isn't installed, and a psutil 3.4 child-wait timeout. In
other words, today's CI is green mostly *because the flaky tests are skipped*, not
because they were fixed.

When the CI-skipped and timing-sensitive files were un-skipped and run 10×:

| Test(s) | Failure rate | Verdict | Root cause |
|---|---:|---|---|
| `task_running_resources_test.py::ConcurrentRunningResourcesTest::test_tasks_parallel` | 7/10 | **Flaky** | `OSError: [Errno 98] Address already in use` on :8082 (collides with `scheduler_test.py` on another xdist worker); `ConnectionRefused` because `sleep(0.5)` wasn't enough for start-up; `assertLess(4.06, 4)` |
| `…::test_tasks_serial` | 5/10 (only when not under load) | **Flaky** | same port collision; `assertGreater(2.4, 4)` once the scheduler is shared |
| `worker_test.py::DynamicDependenciesWithMultipleWorkersTest::test_dynamic_dependencies_other_module` | 10/10 in this file grouping, 0/6 in full `core` | **Order-dependent** | `TaskClassNotFoundException: No task OtherModuleTask`: `other_module` was already imported, so its class is never re-registered after the autouse registry reset |
| `contrib/batch_test.py::BatchClientTest` (10 tests) | 10/10 | **Broken** | `BatchClient.__init__` builds a real boto3 client and calls AWS (`UnrecognizedClientException`). Real network in a unit test. |
| `contrib/s3_test.py` multipart copy/put (4 tests) | 10/10 | **Broken** | part-size assertions (`16777216 != 16777448`) no longer match moto 4.x |
| `server_test.py` skipped tests (ping, raw_ping, 404, save_state) | 0/10 | **Fixed by time**, still skipped | skip reasons point at 2015 Travis jobs |
| `server_test.py::_ServerTest::*` (5) | 5/5 locally | **Collection bug** | abstract base class is collected (`server_client_class = "To be defined…"` → `'str' object is not callable`); needs `__test__ = False` |

Other latent hazards I found by reading code, though they didn't fail in my runs:

- `worker_scheduler_com_test.py` coordinates threads with fixed sleeps: "it should be safe
  to wait 1 second here… after additional 3 seconds, the worker will have…". This breaks
  as soon as a CI runner stalls for more than about 1 s.
- `worker_test.py:1244` resolves `tld.invalid` over real DNS.
- Assertions on wall-clock time: `task_running_resources_test.py` (`assert_duration`),
  `contrib/dataproc_test.py` (`assertLess(time.time() - job_start, 3)`),
  `scheduler_api_test.py::test_get_work_speed` (a performance test inside the unit suite).
- `test/worker_test.py:1574`: `@unittest.skip("Always skip. There are many intermittent failures")`.
- **Python 3.14** changes the default `multiprocessing` start method on Linux to
  `forkserver`. Several tests depend on `fork` semantics: dynamically defined task
  classes, and `mock.patch` applied in the parent and expected in the child. Luigi
  doesn't test 3.14 yet, so this is the next wave of breakage.

The project's issue history shows the same thing. Flaky tests have usually been
**skipped instead of fixed**: spotify/luigi#1111, spotify/luigi#1156, spotify/luigi#1777,
spotify/luigi#1840, and the 23 `skipOnTravisAndGithubActions` markers. Skips build up and
are almost never removed.

### 3.3 CI pipeline issues that cause red builds or waste time

| Issue | Where | Effect |
|---|---|---|
| `fail_ci_if_error: true` on 32 Codecov uploads | `pythonbuild.yml` | A Codecov outage, rate limit, or missing token (fork PRs) turns the build red with no test failing. Looks like flakiness to reviewers. |
| No `timeout-minutes`, no `pytest-timeout` | workflow / tox | A hung `luigid` or child process can keep a job running for up to 6 h (GitHub's default) |
| No `concurrency: cancel-in-progress` | workflow | each push to a PR queues another 34 jobs while the old ones keep running |
| 34 jobs/PR (8 envs × 4 Pythons + lint + docs) | workflow | 28 jobs run 12–25 s of tests; the fixed cost per job dominates. Free-tier public repos are capped at 20 concurrent jobs, so this can mean two waves. |
| `cache-dependency-glob: "pyproject.toml"` | workflow | the cache key ignores `uv.lock`, which pins the actual versions |
| Azurite started with `docker run -d` and no readiness check; `docker login` uses a Spotify-org secret | `scripts/ci/install_start_azurite.sh` | race between container start-up and the first test; login fails for forks |
| MySQL started via `/etc/init.d` with `\|\| true` on every setup command | workflow | setup failures are hidden and show up later as confusing test failures |
| Postgres uses a `services:` container with health checks | workflow | **this already works**; MySQL and Azurite should follow the same pattern |

### 3.4 Local developer experience

A contributor following `CONTRIBUTING.rst` hits several problems:

- **CONTRIBUTING is out of date.** It references `flake8`, `py38`, Travis, and phantomjs.
- **Plain `pytest` isn't supported.** The suite needs `LUIGI_CONFIG_PATH`, fake AWS
  credentials, and an *activated* venv: `bin/luigi` uses `#!/usr/bin/env python`, so 19
  `cmdline_test.py` tests fail unless `.venv/bin` is on `PATH`.
- **Coverage is always on.** `--cov=luigi --cov-report=xml -vv --fulltrace` is in
  `[pytest] addopts`, so every local run, even a single test, pays the 2× coverage
  overhead and produces very verbose output.
- **The default `uv sync` fails.** The `dev` group needs `psycopg2`, which needs
  `pg_config`. Contributors have to know about `--no-default-groups --group common`.
- **There's no fast inner loop.** No `slow` marker exists, so mypy tests, performance
  tests, and multi-second timing tests run on every invocation.
- **CI and local runs disagree.** Local runs execute 23 tests that CI skips, and some of
  those are broken (§3.2). A contributor can't tell whether a red local run is their fault.

---

## 4. Prior art

| Source | Takeaway for this proposal |
|---|---|
| Luo, Hariri, Eloussi, Marinov, *An Empirical Analysis of Flaky Tests* (FSE 2014) | Top root causes: **async wait (45%)**, **concurrency (20%)**, **test-order dependency (12%)**. All three appear in Luigi (§3.2). Recommended fixes: replace sleeps with explicit synchronization, isolate shared resources, reset global state. |
| Google Testing Blog, *Flaky Tests at Google and How We Mitigate Them* (2016) | About 1.5% of test runs flaky at Google. Mitigations: **quarantine** flaky tests out of the blocking path, track flake rates, and treat reruns as a temporary measure rather than a fix. |
| Spotify Engineering, *Test Flakiness – Methods for identifying and dealing with flaky tests* (2019) | Luigi's original authors: measure flakiness centrally, quarantine flaky tests with an owner and a ticket, and remove sleeps and real network calls. |
| GitHub Engineering, *Reducing flaky builds by 18x* (2020) | Automatically detect flakes on rerun, attribute each flake to an owner, and keep a quarantine with a deadline. |
| Martin Fowler, *Eradicating Non-Determinism in Tests* (2011) | Asynchrony: **poll with a timeout instead of sleeping**. Time: inject a clock. Isolation: no shared ports or global state. |
| Tornado `tornado.testing.bind_unused_port` / `AsyncHTTPTestCase.get_http_port()`; CPython `test.support.socket_helper.find_unused_port` | Bind to port 0 and let the OS pick. **Luigi already does this** in `remote_scheduler_test.py:42` and `scheduler_parameter_visibilities_test.py:109`. The two flaky files just don't. |
| `tenacity`-based polling in `test/lock_test.py:39` | Luigi already has an eventual-consistency assertion pattern in-tree. |
| coverage.py 7.4+ `COVERAGE_CORE=sysmon` (PEP 669 `sys.monitoring`) | Very low overhead on 3.12+. Measured: 92 s → 48 s here. |
| `pytest-timeout`, `pytest-rerunfailures`, `pytest-randomly`, `pytest-socket` | Standard tools for hangs, quarantined reruns, order-dependency detection, and blocking real network access. |
| Apache Airflow "selective checks"; GitHub `paths` filters | Run integration jobs only when the relevant `luigi/contrib/*` or `test/contrib/*` files change. Airflow runs a full matrix on `main`/nightly and a reduced one on PRs. |
| spotify/luigi#3398 (xdist for `core`), spotify/luigi#3346 (Codecov Test Analytics, open) | xdist has already helped. Test Analytics would give us the flake and slow-test tracking that Google, Spotify, and GitHub all recommend, for the cost of one `--junitxml` flag. |

---

## 5. Proposal

### Guiding principles

1. **Fix, don't skip.** A skip needs a linked issue and an expiry. A test that can't be
   fixed gets deleted or rewritten.
2. **No sleeps for synchronization.** Use readiness polling, events, or an injected clock.
3. **Hermetic unit tests.** No fixed ports, no real network, no state shared across tests.
4. **CI and local run the same suite.** Environment-specific behavior lives in fixtures,
   not in `if GITHUB_ACTIONS` skips.
5. **Pay fixed CI costs once.** Fewer, fuller jobs on PRs; the full matrix runs nightly
   and on `master`.

### Phase 0: quick wins (small PRs, no test logic changes)

| # | Change | Expected effect | Evidence |
|---|---|---|---|
| 0.1 | Add `rpc-retry-wait: 0` under `[core]` in `test/testconfig/luigi.cfg`; delete the dead `self.sch._wait = lambda: None` hack and the per-test `_rpc_retry_wait = 1` overrides | `server_test.py` 244 s → 3.4 s; `rpc_test.py` −8 s; `worker_test.py::test_connection_error` −2 s | measured |
| 0.2 | Bump test deps to `coverage>=7.6` and set `COVERAGE_CORE=sysmon` in tox `setenv` (on 3.10/3.11 coverage warns and falls back to `ctrace`, which is still ~40% faster than today) | `core` CI 92 s → ~48 s, and the same saving in every coverage-enabled env | measured |
| 0.3 | Add `__test__ = False` to `_ServerTest` | 5 bogus local failures gone | measured |
| 0.4 | Move `--cov…`, `-vv`, `--fulltrace` out of `addopts` into the tox `commands`. Move the `[pytest]` section to `[tool.pytest.ini_options]`. Default `LUIGI_CONFIG_PATH` and fake AWS creds in `conftest.py` via `os.environ.setdefault` | `uv run pytest test/foo_test.py` works out of the box and runs at full speed | |
| 0.5 | In `cmdline_test.py`, call `[sys.executable, "bin/luigi", …]` instead of relying on the shebang | 19 local-only failures gone | measured |
| 0.6 | Add `pytest-timeout` (`timeout = 120`, `timeout_method = thread`) and `timeout-minutes: 20` per job | hangs fail fast with a traceback instead of burning up to 6 h | |
| 0.7 | Add `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: ${{ github.event_name == 'pull_request' }} }` | superseded PR runs are cancelled | |
| 0.8 | Codecov: `fail_ci_if_error: ${{ github.event_name == 'push' }}`, or upload from one aggregate job (§Phase 2) | Codecov outages stop turning PRs red | |
| 0.9 | `cache-dependency-glob: "uv.lock"` | correct cache invalidation | |
| 0.10 | Rewrite the testing section of `CONTRIBUTING.rst` (uv, current Python versions, how to run one test, which envs need services) | lower barrier for contributors | |

**Phase 0 result.** Local serial `core` drops from about 391 s to about 150 s, or about
48 s with `-n auto`. CI `core` drops from about 92 s to about 48 s per Python version.
Infra-caused red builds go away.

### Phase 1: remove the known sources of flakiness

**1.1 A shared `luigid` fixture.** Replace the hand-rolled
`multiprocessing.Process(target=luigi.server.run)` + `sleep()` in
`scheduler_test.py:348`, `task_running_resources_test.py:77`, and `server_test.py:291`
with one helper in `test/helpers.py`:

```python
@contextmanager
def running_luigid(**server_kwargs):
    sock, port = tornado.testing.bind_unused_port()   # OS-assigned, no collisions
    sock.close()
    proc = multiprocessing.Process(target=luigi.server.run,
                                   kwargs=dict(api_port=port, address="127.0.0.1", **server_kwargs))
    proc.start()
    wait_until(lambda: _port_open("127.0.0.1", port), timeout=10)   # readiness, not sleep
    try:
        yield port
    finally:
        proc.terminate(); proc.join(5)
        if proc.is_alive():
            proc.kill(); proc.join()
```

The code under test then gets `--scheduler-port`/`RemoteScheduler(f"http://127.0.0.1:{port}")`.
This removes the confirmed `Address already in use` / `ConnectionRefused` flakes and the
startup sleeps. (Binding and closing has a tiny TOCTOU window; if it ever shows up, pass
the pre-bound socket to tornado via `add_sockets`.)

**1.2 A `wait_until(predicate, timeout, interval=0.01)` helper** (or reuse `tenacity`,
which is already used in `lock_test.py`). Use it to replace sleeps that exist only to
synchronize:

- `worker_scheduler_com_test.py`: poll `self.w.worker_processes == 2` instead of
  `t.join(1); …; t.join(3)`. Shorten the task sleep from 3 s to a `threading.Event` the
  test releases.
- `scheduler_test.py::StableDoneCooldownSecsTest`: wait on the scheduler's task state,
  not on `time_to_run_secs + time_to_check_secs`.
- `custom_metrics_test.py`, `worker_test.py` `sleep(5)`/`sleep(1)` tasks: use events, or
  shrink the duration and set `worker_timeout`/`wait_interval` to match.

**1.3 Remove wall-clock assertions.** `ConcurrentRunningResourcesTest` should check *what
happened* (task B started before task A finished, using recorded timestamps or the
scheduler's `running` set), not `duration < 4`. Move `test_get_work_speed` and
`test_quadratic_behavior` to a `@pytest.mark.perf` suite that runs nightly.

**1.4 Isolate global state.** Make `reset_luigi_registry` in `test/conftest.py` also
`sys.modules.pop()` the helper modules tests import dynamically (`other_module`,
`auto_namespace_test`, etc.), or have those tests use `temporary_unloaded_module`, which
already exists in `test/helpers.py`. Run `pytest -p randomly` nightly (Phase 2) to find
the next order dependency.

**1.5 Audit every CI skip.** Each of the 23 `skipOnTravisAndGithubActions` /
`skipOnGithubActions` sites ends in one of three ways:

- **Un-skip.** It passes now; the `server_test.py` ping/404/save_state tests are proven
  to pass 10/10.
- **Fix.** `batch_test.py`: patch `boto3.client` before constructing `BatchClient`, or use
  `moto.mock_batch`. `s3_test.py` multipart: update expectations for moto 4, or assert
  part counts rather than byte sizes.
- **Delete.** If nobody can explain what the test protects, remove it.

Then delete `skipOnTravisAndGithubActions`, `_running_on_travis`, and
`OVERRIDE_SKIP_CI_TESTS` from `helpers.py`, `tox.ini`, and the workflow.

**1.6 Block real network access in unit tests** with `pytest-socket`
(`--disable-socket --allow-hosts=127.0.0.1,localhost,::1`) in the `core` and `contrib`
envs. That would have caught `batch_test.py` (real AWS) and `worker_test.py:1244` (real
DNS). Integration envs (`mysql`, `postgres`, `azureblob`, `gcloud`, `dropbox`) opt out.

**1.7 A quarantine policy, not a crutch.** Add `pytest-rerunfailures`, but **don't**
enable `--reruns` globally. A test confirmed flaky that can't be fixed right away gets
`@pytest.mark.flaky(reruns=2)` **and** a linked issue, and is listed in
`test/QUARANTINE.md`. A quarantined test that isn't fixed within, say, two releases gets
deleted. Every rerun is reported, so a hidden flake stays visible.

### Phase 2: restructure CI

**Current: 34 jobs per PR.**

```
core × 4 Pythons
mysql × 4
postgres × 4
{aws, unixsocket, apache, azureblob, contrib} × 4
lint
docs
```

**Proposed for PRs: about 12 jobs.**

| Job | Pythons | Contents | Why |
|---|---|---|---|
| `lint` | 3.13 | `ruff check`, `ruff format --check` | seconds; fail fast |
| `core` | 3.10, 3.11, 3.12, 3.13 | `core` with xdist + coverage (sysmon on ≥3.12) | ~1 min each after Phase 0; keeps the per-version signal where most logic lives |
| `integration` | 3.10, 3.13 | `tox run -e pyXY-contrib,pyXY-aws,pyXY-apache,pyXY-unixsocket` in **one job** | each env is 12–25 s; pays the fixed per-job cost once instead of four times |
| `services` | 3.10, 3.13 | `mysql`, `postgres`, `azureblob` in one job, with all three as `services:` containers with health checks | removes init.d MySQL, the `docker run` Azurite race, and the Docker Hub login |
| `docs` | 3.13 | Sphinx | unchanged; could be path-filtered to `doc/**`, `luigi/**` |
| `coverage` | | downloads coverage artifacts from all jobs, `coverage combine`, **one** Codecov upload + junit for Test Analytics (spotify/luigi#3346) | one upload instead of 32; failure isolated to one non-blocking job |

**Nightly (`schedule`) and on push to `master`:**
- the full Python × env matrix (what runs today);
- **Python 3.14** (catches the `forkserver` change early; §3.2);
- `pytest -p randomly` on `core` (order-dependency detection);
- `@pytest.mark.perf` and `@pytest.mark.slow` tests;
- optionally `cdh`/`hdp`/`gcloud`/`dropbox`, which today never run in CI. They should
  either get a nightly job or have their tests explicitly marked as manual-only.

**Optional, later: selective PR checks** using `paths` /
[`dorny/paths-filter`](https://github.com/dorny/paths-filter). Skip `integration` and
`services` when a PR touches only `doc/**`, or only `luigi/contrib/<x>.py` that no
integration env covers. This is Airflow's approach. It's a lower priority because, after
Phase 0 and Phase 2, the full PR set should already finish in a few minutes.

**Required checks** become `lint`, `core (3.10..3.13)`, `integration`, and `services`.
`coverage` is informational.

### Phase 3: keep it fast (ongoing)

- **A `slow` marker plus a fast local default.** Mark `mypy_test.py`, the perf tests, and
  anything over 1 s that can't be fixed. Document `pytest -m "not slow" -n auto` as the
  inner loop.
- **A durations budget in CI.** Add `--durations=25` to CI output so regressions are
  visible in the log. Optionally have a nightly job fail if any single unit test exceeds
  5 s without a `slow` marker.
- **Modernize test dependencies** (each one also removes a source compile or a
  deprecation-warning flood; 798–1,852 warnings per `core` run today):
  `mock<2.0` → `unittest.mock`; `psutil<4.0` → current; `moto<5` → `moto>=5` (`mock_aws`);
  `HTTPretty==0.8.10` → `responses` (already a dependency); `boto` 2 removal; `selenium==3.0.2`.
- **Gradual migration to pytest style.** New tests use pytest fixtures (`tmp_path`,
  `monkeypatch`, the `running_luigid` fixture). Existing `unittest.TestCase` tests are
  converted only when touched. No big-bang rewrite.
- **Track flake rate** in Codecov Test Analytics. Review the top-5 flaky and top-5 slow
  tests once per release.

---

## 6. Expected impact

| Metric | Today | After Phase 0 | After Phases 1–2 |
|---|---:|---:|---:|
| Local `core`, serial, no CI skips | 391 s, 27 failures | ~150 s, 0–3 failures† | < 60 s‡ |
| Local `core`, `-n auto` | ~92 s (coverage always on) | ~48 s | ~20–25 s‡ |
| CI `core` job test step | ~92 s | ~48 s | ~25 s‡ |
| Jobs per PR | 34 | 34 | ~12 |
| Tests skipped only on CI | 23 | 23 | 0 |
| Known structural flake sources | port collisions, startup sleeps, wall-clock assertions, registry leaks, Codecov upload, hangs without timeout | Codecov and hangs fixed | all addressed |

† Measured: 8 failures with only 0.1 applied (5 of them fixed by 0.3, 2 caused by this
sandbox, 1 is the `ConcurrentRunningResourcesTest` flake fixed in 1.1).
‡ Estimates: after removing synchronization sleeps, the ≥1 s tests that remain are mostly
mypy runs and genuine multiprocess tests.

---

## 7. Risks and trade-offs

- **Fewer Pythons for integration envs on PRs.** A 3.11/3.12-only regression in
  `contrib` would be caught nightly instead of on the PR. Luigi is pure Python, and
  `core` still runs on all four versions, so I think the risk is low. The nightly job
  should open an issue automatically on failure so these don't go unnoticed.
- **`pytest-socket` may break tests that have quietly relied on network access.** Those
  are exactly the tests we want to find. Roll it out on `core` first.
- **The coverage 5 → 7 upgrade** may shift some percentages (for example, better branch
  detection), so codecov targets may need a one-time adjustment.
- **Un-skipping old tests** may expose real bugs in Luigi, not only in the tests. Triage
  them as bugs.
- **Phase 1 changes test code**, so it carries more review burden. Small PRs, one file or
  one pattern each, keep it reviewable.

## 8. Open questions for maintainers

1. Are you comfortable running integration envs on only min/max Python on PRs, with the
   full matrix nightly?
2. Should Codecov stay a required check, or become informational?
3. `cdh`/`hdp`/`gcloud`/`dropbox`/`visualiser` envs never run in CI today. Should they be
   revived nightly, or retired (with `codecov.yml` ignores kept)?
4. Should we adopt Codecov Test Analytics (spotify/luigi#3346) for flake tracking, or keep
   tracking in GitHub issues?
5. Quarantine expiry: is "two releases, then delete" acceptable?

## 9. Suggested PR sequence

1. Phase 0.1 + 0.3 (test config + `_ServerTest`): tiny, highest local payoff.
2. Phase 0.2 (coverage 7 + sysmon).
3. Phase 0.6–0.9 (workflow hygiene: timeouts, concurrency, Codecov, cache key).
4. Phase 0.4–0.5 + 0.10 (plain-`pytest` local experience + CONTRIBUTING).
5. Phase 1.1 (`running_luigid` fixture), then 1.2–1.3 one file at a time.
6. Phase 1.5 skip audit (one PR per file) → remove skip helpers.
7. Phase 1.4, 1.6, 1.7.
8. Phase 2 workflow restructure + nightly.
9. Phase 3 ongoing.

---

## Appendix A: Reproduction

```bash
uv sync --no-default-groups --group common
export PATH=$PWD/.venv/bin:$PATH LUIGI_CONFIG_PATH=$PWD/test/testconfig/luigi.cfg \
       AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x LC_ALL=C.UTF-8
M='not minicluster and not gcloud and not mysql and not postgres and not unixsocket and not contrib and not apache and not aws and not azureblob and not dropbox'

# Serial per-test durations (local experience)
python test/runtests.py --doctest-modules -m "$M" --durations=60 --no-cov

# CI-like
GITHUB_ACTIONS=true COVERAGE_PROCESS_START=$PWD/.coveragerc \
  python test/runtests.py --doctest-modules -m "$M" -n auto --dist=loadfile

# Coverage 7 comparison
uv pip install "coverage>=7.6"
GITHUB_ACTIONS=true COVERAGE_CORE=sysmon COVERAGE_PROCESS_START=$PWD/.coveragerc \
  python test/runtests.py --doctest-modules -m "$M" -n auto --dist=loadfile

# server_test with retry wait disabled (copy luigi.cfg, add `rpc-retry-wait: 0` under [core])
LUIGI_CONFIG_PATH=/path/to/fast.cfg python test/runtests.py test/server_test.py --no-cov -k "not _ServerTest and not UNIX"

# Flake hunt: CI-skipped + timing-sensitive files, unskipped, repeated
for i in $(seq 10); do
  python test/runtests.py test/task_running_resources_test.py test/scheduler_test.py \
    test/worker_test.py test/server_test.py test/contrib/s3_test.py test/contrib/batch_test.py \
    -n 4 --dist=loadfile --no-cov -q
done
```

## Appendix B: Raw measurements

| Run | Result |
|---|---|
| `core` serial, no CI skips | 27 failed / 1473 passed / 38 skipped, 391.6 s |
| `core` CI-like, coverage 5.5 | 2 failed\* / 1467 passed / 57 skipped, 91.5 s |
| `core` CI-like, no coverage | same counts, 45.6 s |
| `core` CI-like, coverage 7.17 ctrace | same counts, 56.2 s |
| `core` CI-like, coverage 7.17 sysmon | same counts, 47.0 s |
| `core` CI-like ×6 (`-n 4` ×3, `-n 12` ×3) | identical 2 failures\* each run; 42–46 s |
| `server_test.py` with `rpc-retry-wait: 0` | 54 passed, 3.4 s (vs 244 s) |
| Stress, 10 iterations (5 idle + 5 with 8 busy loops) | 14–16 failures per iteration; breakdown in §3.2 |
| `contrib` / `aws` / `apache` / `scheduler` | 12.4 s / 24.6 s / 12.9 s / 22.1 s |
| `uv sync --group common` cold (empty cache) | 4 s (3.13), 6 s (3.10) |
| Collection (`--collect-only`, all tests) | 4.2 s |

\* `test_ssh.py::…test_check_output_fail_connect` (no `ssh` binary in the sandbox) and
`worker_task_test.py::…test_cleanup_children_on_terminate` (psutil 3.4 child-wait timeout
in the container). Both are environment-specific and failed in every run, not
intermittently.
