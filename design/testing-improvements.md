# Proposal: Faster, deterministic tests for Luigi (local and CI)

| | |
|---|---|
| **Status** | Draft for maintainer review (rev. 3: category-preserving test selection; no nightly perf suite) |
| **Date** | 2026-11-26 |
| **Baseline** | `spotify/luigi` `master` @ `3e75c0c` (this fork is 30 commits behind; every finding was re-checked on upstream) |
| **Scope** | `test/`, `tox.ini`, `pyproject.toml`/`uv.lock` (test deps), `.github/workflows/pythonbuild.yml`, `scripts/ci/` |
| **Non-goals** | 100% coverage in CI; rewriting the suite; a 5-minute end-to-end CI for every integration |

---

## 1. Summary

Revision 1 of this doc was based only on local measurements. Revision 2 adds what
upstream CI actually does: 326 `Build` runs, per-job timings for three recent `master`
runs, and the failing jobs of ten failed runs. It also adds a full audit of which tests
tox and CI actually run.

1. **One job sets the wall time of every PR, and the cause is one stale lockfile pin.**
   Upstream runs take **17–32 min**. In each sampled run, `core (py314-core)` takes
   **17.5–25.4 min**, while every other one of the 43 jobs finishes in ≤ 6.3 min (most in
   about 1 min). The reason: `uv.lock` pins **mypy 1.14.1**, which has no compiled wheel
   for Python 3.14. `test/mypy_test.py` therefore runs mypy *as pure Python*, under
   *coverage 5.5's pure-Python tracer*, and `--dist=loadfile` puts all 5 of those tests on
   *one* xdist worker. I reproduced it locally: py314 `core` takes **18m22s**, of which
   the mypy tests take **1,028s**.
   - **Bumping mypy to ≥ 1.17 (compiled on 3.14): 1,104s → 117s.**
   - **Also moving to coverage 7 + `COVERAGE_CORE=sysmon`: → 62s.**

   This is roughly a **4× cut in PR wall time from a one-line lockfile change**.
2. **Coverage 5.5 is the next-biggest cost everywhere else.** It only gets its C tracer
   on 3.10, where it compiles from source; on 3.11–3.14 it falls back to pure Python. That
   is why `py310-core` takes about 2 min while py311–313 take 4–6 min. Coverage 7 with
   `sysmon` measured **92s → 48s** for `core` on 3.13.
3. **CI and local runs skip a lot of tests, in nine different ways** (§3.5). Audited
   against upstream:
   - 16 tests selected by no CI env;
   - 11 test modules (≈90 tests) skipped *at import time*, which is invisible in CI output:
     - `mongo_test.py` can never run, because the pinned `pymongo 3.4.0` can't be imported
       on Python ≥ 3.10;
     - `redis` and `pykube` aren't installed in any group;
   - 9 tests hidden by `--ignore-glob="**/_*"`;
   - 3 tests whose nose-style names pytest never collects (dropped silently in the 2021
     nose→pytest migration);
   - 18 CI-only skip sites;
   - **two tox envs, `cdh` and `hdp`, that download Hadoop and then select 0 tests**,
     because their `minicluster` marker died with snakebite in 2019 (spotify/luigi#2833);
   - 32 tests that run twice per Python.
4. **Flakiness exists, but in upstream CI it's hidden rather than hitting PRs.** No
   re-run attempts are visible in recent history. In the ten failed runs I classified,
   the visible causes are lint, typecheck, and a PR-caused dependency failure; four are
   unconfirmable because logs need sign-in or have expired. **None was a Codecov or
   infra failure.** Locally, though, the CI-skipped tests contain a real flake (two files
   share hard-coded port 8082; fixed startup sleeps; wall-clock assertions), an
   order-dependent test, and 14 tests that are simply broken. One of them calls real AWS.
5. **Small CI hygiene issues.**
   - All 43 jobs race to save the *same* `setup-uv` cache key. That produces a "Failed to
     save: Unable to reserve cache… another job may be creating this cache" warning on
     most jobs, and whichever Python wins writes the cache for everyone.
   - Every job emits Node 20 deprecation warnings from the Codecov action.
   - There's no job timeout and no cancellation of superseded runs.
   - Each run uses **1h13m–1h27m of runner time**.

The proposal is phased. **Phase 0** is a handful of tiny PRs: the mypy bump comes first,
then coverage 7 and CI hygiene. **Phase 1** fixes the tox/marker design so tests can't
fall out of CI unnoticed: `core` becomes a path, and each contrib test gets exactly one
category, still reported as its own check. It also fixes the known flake sources.
**Phase 2** trims CI from 43 jobs to about 26 per PR, keeping `core` on every Python and
one check per category, and adds a nightly full matrix. **Phase 3** is ongoing
hygiene.

---

## 2. Method

| Source | What I did |
|---|---|
| Upstream Actions history (public web UI) | Listed 50 recent runs and the first two pages of failed runs; read per-job timings and annotations (the `/usage` and summary pages) for three successful `master` runs (`45747287888`, `45092229826`, `45093235493`) and the failed jobs of ten failed runs. Job logs need sign-in, so failing test names weren't visible. *(The Actions API wasn't available to this session for `spotify/luigi`; everything was read from public pages.)* |
| Upstream clone @ `3e75c0c` | Collected every test with a plugin that dumps nodeid + markers, then evaluated each tox env's selection (`-m …` expression + path) against it (§3.5). Collected with `-rs` to list import-time module skips. |
| Local timing (4 vCPU, roughly a GitHub `ubuntu-22.04` runner) | `core` CI-style (`-n auto --dist=loadfile`, `GITHUB_ACTIONS=true`, coverage on) on Python 3.10, 3.13 and 3.14, with and without coverage, with coverage 7 (`ctrace`, `sysmon`), and with mypy 1.14.1 vs 1.18.2. |
| Local flake hunt | `core` 6× (including 3× oversubscribed). The CI-skipped and timing-sensitive files, un-skipped, 10× (5 idle, 5 under CPU starvation). |

Commands are in [Appendix A](#appendix-a-reproduction).

---

## 3. Findings

### 3.1 Upstream CI: where the wall-clock time goes

**Run history.** The `Build` workflow had **326 runs; 106 (33%) failed.** Of the 49
most recent completed runs, 8 failed (16%). Successful runs took **16m51s–32m27s**. No
run shows a re-run attempt.

**Per-job timings**, three successful `master` pushes (43 jobs each):

| Job | Run `45747287888` | Run `45092229826` | Run `45093235493` |
|---|---:|---:|---:|
| **Wall time** | **24m51s** | **17m39s** | **25m27s** |
| **`core (py314-core)`** | **24m47s** | **17m34s** | **25m22s** |
| next-longest job | 5m30s (py311-core) | 6m16s (py312-core) | 5m27s (py311-core) |
| `core (py311/312/313)` | 5m14s–5m30s | 4m04s–6m16s | 3m41s–5m27s |
| `core (py310-core)` | 2m33s | 2m09s | 2m50s |
| `aws` jobs | 1m10s–2m07s | 58s–2m15s | 56s–2m44s |
| `unixsocket` jobs | 1m27s–4m22s | 1m30s–1m47s | 1m27s–4m21s |
| `contrib` / `apache` / `azureblob` / `mysql` / `postgres` jobs | 29s–1m22s | 32s–1m07s | 27s–1m25s |
| `lint` / `typecheck` / `docs` | 9s / 21s / 34s | 11s / 29s / 26s | 13s / 29s / 39s |
| **Total runner time** | **1h24m10s** | **1h12m51s** | **1h26m35s** |

**Root cause of the py314 outlier** (reproduced locally, `core`, CI-style):

| Python | mypy | coverage | `mypy_test.py` (5 tests, one worker) | `core` wall |
|---|---|---|---:|---:|
| 3.10 | 1.14.1 (compiled) | 5.5 (C tracer, built from sdist) | ~56s | 111s |
| 3.14 | 1.14.1 (**pure Python**: no cp314 wheel) | none | ~147s | 181s |
| 3.14 | 1.14.1 (**pure Python**) | 5.5 (**pure-Python tracer**) | **1,028s** (≈205s each) | **1,104s** |
| 3.14 | **1.18.2** (compiled) | 5.5 (pure-Python tracer) | 39s | **117s** |
| 3.14 | **1.18.2** (compiled) | **7.x, `COVERAGE_CORE=sysmon`** | 26s | **62s** |

mypy ships compiled (mypyc) wheels for 3.14 starting with 1.17 (1.16.1: pure Python;
1.17.1, 1.18.2, 2.4.1: compiled, checked by installing each one). `pyproject.toml`
says only `"mypy"`; the version is held back purely by `uv.lock`. `mypy_test.py` passes
on 1.18.2.

The same two factors explain the smaller spread between the other Python versions. py310
gets coverage's compiled tracer and runs `core` in about 2 min. py311–313 get the
pure-Python tracer plus compiled mypy, and take 4–6 min.

### 3.2 Upstream CI: what makes runs red

The ten failed runs I classified (job logs need sign-in, so classification is from the
job list and annotations):

| Category | Runs | Notes |
|---|---:|---|
| `others (lint)` fails in about 8–13s; `typecheck` and `docs` are then cancelled | 4 | deterministic; `lint` failing cancels other `others` jobs via fail-fast |
| `others (typecheck)` | 1 | deterministic |
| PR dependency bump breaks nearly every job | 1 | PR-caused |
| A single `core`/`aws` job fails | 4 | probably real test failures; unconfirmable (logs need sign-in or have expired) |
| Codecov / Docker / MySQL / timeout | **0** | none seen in annotations |

Older failures include long streaks of 10–15 consecutive failing pushes on a single PR
(for example spotify/luigi#3427, spotify/luigi#3429). That pattern suggests contributors
use CI as their test runner, which fits the local-setup friction in §3.6.

**Conclusion.** Upstream red builds are mostly real failures. Flakiness is
*structurally present* (§3.4) but currently kept off PRs by skips. The main maintainer
pain in CI is **latency**: a 17–30 min feedback loop, entirely due to one job.

**Annotations seen on green runs:**
- `setup-uv` "Failed to save: Unable to reserve cache with key
  `setup-uv-2-x86_64-unknown-linux-gnu-ubuntu-22.04-3.10.12-pruned-<hash>`, another job
  may be creating this cache". The key contains neither the matrix Python nor `uv.lock`,
  so **43 jobs with different Python versions and dependency sets share one cache
  entry**, and the first job to finish decides its contents.
- "Node.js 20 is deprecated … `actions/github-script@60a0d83…` … forced to run on
  Node.js 24" (40–77 per run, coming from `codecov/codecov-action@v5`).

### 3.3 Local: where the time goes (non-mypy)

Serial `core` with no CI skips, i.e. what a contributor running the suite gets (fork @
v3.8.0, same test code as upstream for these files): **391s, 27 failures.**

| File | Serial time | Main cause |
|---|---:|---|
| `server_test.py` | **244s** | 4 × `test_404` at 60s each. `rpc-retry-wait` defaults to 30s (`luigi/rpc.py:154`), and the test's `self.sch._wait = lambda: None` (`test/server_test.py:296`) is a dead hack left over from before tenacity |
| `worker_test.py` | 35s | tasks that `sleep(1..5)`; real DNS lookup of `tld.invalid` (`:1244`) |
| `worker_scheduler_com_test.py` | 18s | 3s task sleeps plus `t.join(1)`/`t.join(3)` used as synchronization |
| `mypy_test.py` | 14s (3.13) → 1,028s (3.14, CI) | see §3.1 |
| `rpc_test.py` | 13s | 4 × 2s retry waits |
| `scheduler_test.py`, `task_running_resources_test.py` | 12s, 11s | a real `luigid` on hard-coded :8082, `sleep()` for start-up |

- **47 tests that take ≥1s each account for 92% of serial time**, and most of that is
  sleeps.
- Adding `rpc-retry-wait: 0` to the test config takes `server_test.py` from **244s to
  3.4s**.
- Dependency installation is **not** a bottleneck: a cold `uv sync` takes 4–6s.

### 3.4 Flakiness: reproduced root causes

With CI skips active, `core` was deterministic in 6 of 6 runs, including 3× CPU
oversubscription. When the CI-skipped and timing-sensitive files were un-skipped, 10×:

| Test(s) | Failure rate | Verdict | Root cause |
|---|---:|---|---|
| `task_running_resources_test.py::ConcurrentRunningResourcesTest::test_tasks_parallel` | 7/10 | **Flaky** | `OSError: [Errno 98] Address already in use` on :8082 (`scheduler_test.py` binds it on another xdist worker); `ConnectionRefused` after `sleep(0.5)`; `assertLess(4.06, 4)` |
| `…::test_tasks_serial` | 5/10 | **Flaky** | same port collision |
| `worker_test.py::…::test_dynamic_dependencies_other_module` | 10/10 in one file grouping, 0/6 in full `core` | **Order-dependent** | `other_module` was already imported, so `OtherModuleTask` isn't re-registered after the autouse registry reset |
| `contrib/batch_test.py::BatchClientTest` (10) | 10/10 | **Broken** | `BatchClient.__init__` calls real AWS (`UnrecognizedClientException`) |
| `contrib/s3_test.py` multipart (4) | 10/10 | **Broken** | part-size expectations don't match moto 4.x |
| `server_test.py` ping/404/save_state | 0/10 | **Passing, still skipped** | skip reasons point at 2015 Travis jobs |
| `server_test.py::_ServerTest::*` (5) | 5/5 locally | **Collection bug** | abstract base is collected; needs `__test__ = False` |

Latent hazards found by reading code:
- sleep-based thread coordination in `worker_scheduler_com_test.py`;
- wall-clock assertions in `task_running_resources_test.py`, `contrib/dataproc_test.py`,
  and `scheduler_api_test.py::test_get_work_speed`;
- `worker_test.py:1574` `@unittest.skip("Always skip. There are many intermittent failures")`.

The project's history shows flakes have usually been skipped instead of fixed:
spotify/luigi#1111, spotify/luigi#1156, spotify/luigi#1777, spotify/luigi#1840.

### 3.5 How tox is used, and why tests don't run in CI

**How it works today.** `tox.ini` defines 64 envs (`py{310..314}-{cdh,hdp,core,contrib,apache,aws,gcloud,mysql,postgres,unixsocket,azureblob,dropbox}` + `visualiser`, `docs`, `lint`, `typecheck`). Each test env:

- picks a dependency group (`common` for most);
- runs `test/runtests.py` with a hand-written `-m` expression.

`core` is defined *negatively*: `not minicluster and not gcloud and not mysql and …`.
`contrib` is `test/contrib/ -m "contrib or unmarked"`, where `unmarked` is added by a
`conftest.py` hook. CI runs 8 of the 12 factors on 5 Pythons, plus the 3 `others`, giving
43 jobs. Each job installs tox, then runs `uvx --with tox-uv tox run` for one env.

**Every way a test can avoid running in CI** (counted with an `nodeid → markers → env`
map over all 1,868 tests collected upstream):

| # | Mechanism | Tests affected | Detail |
|---|---|---:|---|
| 1 | **Env never runs in CI** | 16 (`gcloud`) + 25 (`dropbox`) + visualiser | `gcloud` and `dropbox` need real cloud credentials. Remnants of the Travis setup (`test/gcloud-credentials.json.enc`, the unreferenced `scripts/ci/conditional_tox.sh`, `GCS_TEST_*`/`DROPBOX_APP_TOKEN` in `passenv`) are dead. `visualiser` needs selenium 3.0.2 + phantomjs. |
| 2 | **Env selects nothing** | 0 (env still costs a Hadoop download) | `cdh`/`hdp` run `-m minicluster`. No test has had that marker since the minicluster tests were removed with snakebite (spotify/luigi#2833, 2019). The `cdh`/`hdp` markers are registered but never used. |
| 3 | **Import-time module skip** (0 items collected, so invisible) | ≈90 in 11 modules | `mongo_test.py` (9): **`pymongo==3.4.0` can't be imported on Python ≥3.10** (`collections.MutableMapping`), so it can never run. `redis_test.py` (2): `redis` isn't in any dependency group. `kubernetes_test.py` (3): `pykube` isn't installed. `esindex_test.py` (6, marked `aws`): needs an Elasticsearch server. `hdfs/webhdfs_client_test.py` (2, marked `apache`): needs `hdfs`, which only the `cdh`/`hdp` groups install. `contrib/test_ssh.py` (11): needs an SSH server. `gcs_test.py` (19), `bigquery_gcloud_test.py` (15), `dataproc_test.py` (9): need GCP. `dropbox_test.py` (25): needs a token. `postgres_with_server_test.py` (4) and `docker_runner_test.py` (7) probably run in CI (where a server or Docker is available) but skip silently locally. |
| 4 | **Hidden by `--ignore-glob="**/_*"`** | 9 | `test/_mysqldb_test.py` (1), `test/_test_ftp.py` (5), `test/contrib/_webhdfs_test.py` (3). Never run anywhere. |
| 5 | **Never collected by pytest** (nose naming) | 3 | `import_test.py::import_test` and `::import_luigi_test` (the "every module imports" smoke test) and `server_test.py::patching_test`. nose collected `*_test` methods; pytest only collects `test*`. They were dropped silently in the nose→pytest migration (spotify/luigi#3048). Revived, `import_test` needs one tweak: `mypy.expandtype` can't be imported standalone (an import cycle inside mypy) unless `mypy.main` is imported first. |
| 6 | **CI-only skips** | 18 sites | `skipOnTravisAndGithubActions` / `skipOnGithubActions` (§3.4). `OVERRIDE_SKIP_CI_TESTS` re-enables them only in `unixsocket`. |
| 7 | **Selected by no CI env** | 16 | all `gcloud`-marked (`beam_dataflow_test.py` 11, `bigquery_test.py` 4, `bigquery_avro_test.py` 1). These are mocked unit tests that could run in `contrib`, but the `gcloud` marker excludes them from `core` and `contrib` alike. |
| 8 | **Run twice per Python** | 32 | unmarked tests under `test/contrib/` match both `core` (not excluded) and `contrib` (`or unmarked`) |
| 9 | **Same venv built repeatedly** | | `apache`, `aws`, `mysql`, `contrib`, `azureblob` and `core` all use the `common` group, yet each is a separate tox env and CI job: 6 identical environments per Python, 30 per run |

**Why this keeps happening.** Selection is a hand-maintained *exclusion list*: `core`'s
`-m`. Any new marker, or any marker whose env gets dropped, silently removes tests from
every CI job. Import-time `raise unittest.SkipTest(...)` for missing dependencies turns
"dependency missing in CI" into "zero tests collected", with no signal. Nothing checks
that every collected test is selected by at least one CI env.

Also: `DOCKERHUB_TOKEN` is in tox `passenv`, but the workflow never sets it, so
`install_start_azurite.sh`'s `docker login -u spotifyci` always fails. That's harmless,
because the image comes from `mcr.microsoft.com`, but it's misleading.

### 3.6 Local developer experience

- `CONTRIBUTING.rst` is out of date: it mentions `flake8`, `py38`, Travis, and phantomjs.
- Plain `pytest` isn't supported. The suite needs `LUIGI_CONFIG_PATH`, fake AWS creds,
  and an *activated* venv. `bin/luigi` has `#!/usr/bin/env python`, so 19
  `cmdline_test.py` tests fail unless `.venv/bin` is on `PATH`.
- Coverage, `-vv` and `--fulltrace` are in `[pytest] addopts`, so even a single-test run
  pays the coverage overhead.
- The default `uv sync` (`dev` group) needs `pg_config` because of `psycopg2`.
- There's no `slow` marker for a fast inner loop.
- Local runs execute tests that CI skips, and some of those are broken, so a red local
  run doesn't tell a contributor whether they caused it.

---

## 4. Prior art

| Source | Takeaway |
|---|---|
| Luo et al., *An Empirical Analysis of Flaky Tests* (FSE 2014) | Top causes: async wait (45%), concurrency (20%), order dependency (12%). All three are present here (§3.4). |
| Google Testing Blog, *Flaky Tests at Google and How We Mitigate Them* (2016) | Quarantine flaky tests out of the blocking path, track flake rates; reruns are a temporary measure, not a fix. |
| Spotify Engineering, *Test Flakiness – Methods for identifying and dealing with flaky tests* (2019) | From Luigi's original home: measure flakiness centrally, quarantine with an owner, remove sleeps and real network calls. |
| GitHub Engineering, *Reducing flaky builds by 18x* (2020) | Detect flakes on rerun automatically, attribute them to an owner, quarantine with a deadline. |
| Martin Fowler, *Eradicating Non-Determinism in Tests* (2011) | Poll with a timeout instead of sleeping; inject the clock; isolate shared resources. |
| Tornado `bind_unused_port` / `AsyncHTTPTestCase.get_http_port()` | Already used in `remote_scheduler_test.py:42` and `scheduler_parameter_visibilities_test.py:109`; the two flaky files just don't use it. |
| coverage.py ≥7.4 `COVERAGE_CORE=sysmon` (PEP 669) | Very low overhead on 3.12+. Measured 92s → 48s (3.13) and 117s → 62s (3.14). |
| mypyc-compiled mypy wheels | Compiled mypy is several times faster than pure Python. On 3.14 that requires mypy ≥1.17. |
| `pytest-timeout`, `pytest-rerunfailures`, `pytest-randomly`, `pytest-socket` | Standard tools for hangs, quarantined reruns, order-dependency detection, and blocking real network access. |
| tox 4 `labels`; one pytest invocation with an OR-ed marker expression | Run several logical suites in one env/job instead of one job each. |
| Apache Airflow "selective checks"; GitHub `paths` filters | Reduced matrix on PRs, full matrix on `main`/nightly. |
| spotify/luigi#3398 (xdist), spotify/luigi#3346 (Codecov Test Analytics, open) | xdist already helped `core`. Test Analytics would add flake and slow-test tracking. |

---

## 5. Proposal

### Guiding principles

1. **Fix, don't skip.** A skip needs a linked issue and an expiry.
2. **No sleeps for synchronization.** Use readiness polling, events, or an injected clock.
3. **Hermetic unit tests.** No fixed ports, no real network, no state shared across tests.
4. **Opt-in, not opt-out, selection.** A test runs in CI unless it explicitly says why
   it can't, and CI verifies that.
5. **Pay fixed CI costs once.** Fewer, fuller jobs on PRs; the full matrix nightly.

### Phase 0: quick wins (tiny PRs, no test logic changes), in priority order

| # | Change | Effect | Evidence |
|---|---|---|---|
| **0.1** | **`uv lock --upgrade-package mypy`** (to ≥1.17, e.g. 1.18.2), and optionally a `"mypy>=1.17"` floor in the `common`/`docs` groups | **py314 `core`: 1,104s → 117s. PR wall time: ~25 min → ~6 min** | measured |
| 0.2 | Coverage `>=7.6` in test deps and `COVERAGE_CORE=sysmon` in tox `setenv` (3.10/3.11 fall back to `ctrace` with a warning) | py314 `core` 117s → 62s; py313 92s → 48s; py311–313 jobs should drop from 4–6 min towards about 2 min | measured (3.13, 3.14) |
| 0.3 | Add `rpc-retry-wait: 0` under `[core]` in `test/testconfig/luigi.cfg`; delete the dead `_wait` hack and the per-test `_rpc_retry_wait = 1` overrides | `server_test.py` 244s → 3.4s locally; −10s across `rpc_test`/`worker_test` | measured |
| 0.4 | `setup-uv`: `cache-dependency-glob: "uv.lock"` + `cache-suffix: ${{ matrix.tox-env }}` | stops 43 jobs racing over one cache entry; caches the right wheels per Python | annotation evidence |
| 0.5 | `concurrency: {group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: ${{ github.event_name == 'pull_request' }}}`; `timeout-minutes: 20` per job; `pytest-timeout` (`timeout = 300`) | superseded runs cancelled; hangs fail fast | |
| 0.6 | Bump `codecov/codecov-action` once a Node 24 release is out; set `fail_ci_if_error: ${{ github.event_name == 'push' }}` | removes 40–77 warnings per run; fork PRs aren't blocked by Codecov | |
| 0.7 | `__test__ = False` on `_ServerTest`; rename the 3 nose-style methods to `test_*` (and fix `import_test` for the mypy import cycle) | +3 real tests, −5 bogus local failures | measured |
| 0.8 | Delete the dead `cdh`/`hdp` envs, `setup_hadoop_env.sh` usage, `conditional_tox.sh`, the encrypted Travis GCP creds, `DOCKERHUB_TOKEN`/`docker login`, and the unused `minicluster`/`cdh`/`hdp` markers | less to maintain and to misread | §3.5 |
| 0.9 | Move `--cov…`, `-vv` and `--fulltrace` from `addopts` into the tox `commands`; move `[pytest]` to `[tool.pytest.ini_options]`; default `LUIGI_CONFIG_PATH` and fake AWS creds in `conftest.py`; call `sys.executable` in `cmdline_test.py` | `uv run pytest test/x_test.py` works out of the box | measured |
| 0.10 | Rewrite the testing section of `CONTRIBUTING.rst` | lower barrier for contributors | |

**Phase 0 result.** PR wall time drops from 17–30 min to about 5–6 min (the longest
remaining jobs are py311–313 `core` under coverage 5.5; 0.2 shortens them further).
Runner time per run drops by roughly 20 min.

### Phase 1: make test selection trustworthy, and fix the flakes

**1.1 Make `core` a path, and give every contrib test exactly one category.** The goals:

- `core` stays its own first-class suite, because it's what every Luigi user depends on.
- A failure still says *which* category broke ("gcloud failed", not "integration
  failed").
- No test can fall out of CI unnoticed.

The test tree is already almost organized this way. Of 1,868 tests, every
category-marked test except 5 lives under `test/contrib/`, and no test carries two
categories.

| Rule | How |
|---|---|
| **`core` = everything outside `test/contrib/`** | `pytest test --ignore=test/contrib` replaces the hand-maintained `not minicluster and not gcloud and not …` expression. A new category can never remove tests from `core`, and `core` can't accidentally pick up contrib tests. |
| **Every test under `test/contrib/` has exactly one category marker** (`contrib`, `aws`, `apache`, `gcloud`, `mysql`, `postgres`, `azureblob`, `dropbox`, plus new ones as modules need them) | A `pytest_collection_modifyitems` hook in `conftest.py` *errors* when a contrib test has zero or more than one category. This replaces the `unmarked` auto-marker, and with it the 32 tests that run in both `core` and `contrib` today (`datadog_metric`, `external_daily_snapshot`, `hadoop_jar`, `hive`, `pai`, `presto` need a marker). |
| **Each category keeps its own tox env and CI check** | `pyXY-<category>`: `pytest test/contrib -m <category>`, with that category's dependency group. When it fails, the check name says which category. |
| **Tests that need real external resources are flagged separately from their category** | e.g. `@pytest.mark.gcloud` + `@pytest.mark.requires_credentials`. The 16 *mocked* `gcloud` tests (`beam_dataflow_test.py`, `bigquery_test.py`, `bigquery_avro_test.py`) can then run in a `gcloud` CI job with the `gcloud` dependency group, while tests that need a real GCP project are excluded explicitly instead of the whole category disappearing from CI. The same applies to `dropbox`. |
| **`unixsocket`** | The only category outside `test/contrib/` (5 tests in `server_test.py`, testing a `luigid` feature with an extra dependency). Either move it into `core` by adding `requests-unixsocket` to the core dependencies, or keep it as a category and let the audit (1.2) allow-list it. |

This also lines up with the earlier idea of splitting each `contrib` module into its own
package. Each category is already a self-contained test directory + marker + dependency
group + CI check, so a future split would mostly move files rather than untangle
selection logic. Nothing here commits to that split.

**1.2 A CI "selection audit".** A small script (≈40 lines) runs
`pytest --collect-only` with a plugin that dumps nodeid + markers, evaluates every CI
env's selection, and **fails if a test is selected by no CI env** unless it carries an
explicit `@pytest.mark.requires_credentials`/`@pytest.mark.manual(reason=…)`. With 1.1
in place the rule is simple: each test belongs to `core` *xor* exactly one category, and
each category is either in the CI matrix or explicitly listed as not run. It should also fail on **unexpected
import-time skips**: in CI, set an env var that makes a missing optional dependency
raise instead of `SkipTest` (or check `-rs` output against an allowlist of reasons such
as "needs Elasticsearch"). This turns all nine mechanisms in §3.5 into visible failures.

**1.3 Resolve the dead and hidden tests**, one PR each:

| Tests | Action |
|---|---|
| `mongo_test.py` | bump `pymongo` (3.4.0 → current); runs in `core` with mocks or with a `mongo` service |
| `redis_test.py`, `kubernetes_test.py` | add the dependencies to `common`, or delete the tests if the contrib modules are unmaintained |
| `hdfs/webhdfs_client_test.py` | add `hdfs` to `common` (it's tiny), or delete |
| `esindex_test.py` | it's marked `aws` by mistake; give it an `elasticsearch` service marker plus a nightly service job, or `manual` |
| `_mysqldb_test.py`, `_test_ftp.py`, `_webhdfs_test.py` | rename and fix, or delete |
| 18 CI-only skips | un-skip (`server_test` passes), fix (`batch_test`: patch `boto3.client`/`moto.mock_batch`; `s3_test` multipart: update for moto), or delete. Then remove `skipOnTravisAndGithubActions`, `_running_on_travis` and `OVERRIDE_SKIP_CI_TESTS`. |
| `gcloud`/`dropbox` real-service tests | decide: a nightly job with org secrets, or `manual` |

**1.4 A shared `running_luigid` fixture** (in `test/helpers.py`) that binds an
OS-assigned port (`tornado.testing.bind_unused_port`), starts the server, and **polls
for readiness** instead of sleeping. Use it in `scheduler_test.py`,
`task_running_resources_test.py` and `server_test.py`. This removes the confirmed
`Address already in use` / `ConnectionRefused` flake.

**1.5 A `wait_until(pred, timeout)` helper** (or `tenacity`, already used in
`lock_test.py`) to replace sleeps used for synchronization:
`worker_scheduler_com_test.py`, `StableDoneCooldownSecsTest`, `custom_metrics_test.py`,
and the `worker_test.py` sleep tasks.

**1.6 Remove wall-clock assertions.** In `ConcurrentRunningResourcesTest` and
`dataproc_test.py`, assert on the order of events (task B started before task A
finished) instead of `duration < 4`.

`scheduler_api_test.py::test_get_work_speed` and `test_quadratic_behavior` are a
different case. They guard against real past regressions (the "almost 4 minutes" `get_work`
slowdown reported in spotify/luigi#986, and quadratic scheduling), so they stay in `core`
rather than moving to a separate performance suite. Make them robust instead:

- assert on **scaling, not absolute time**: run at N and 4N and check that the time
  ratio stays well below quadratic. Or count calls/iterations with a patched helper,
  which is fully deterministic.
- shrink N to the smallest size that still separates linear from quadratic behavior.
  `test_get_work_speed` currently builds 200,000 tasks: 5s with no coverage, 24s under
  CI's py314 coverage.

A dedicated nightly performance job isn't proposed. It should earn its place, for
example if a performance regression ever gets past these guard tests.

**1.7 Isolate global state.** Have the registry-reset fixture also drop dynamically
imported helper modules (`other_module`, …), or use the existing
`temporary_unloaded_module`.

**1.8 Block real network access** in `core` with `pytest-socket` (allow localhost). It
would have caught `batch_test.py` (real AWS) and `worker_test.py:1244` (real DNS).

**1.9 A quarantine policy.** `pytest-rerunfailures` *only* for tests listed in
`test/QUARANTINE.md` with an issue link, and an expiry of two releases.

**1.10 Run `mypy_test.py` once, not 5× per run.** It tests the mypy *plugin*, not
Luigi's runtime behavior on each Python. Move it to the `typecheck` env (single Python),
or mark it `slow` and run it on one Python in CI. This also makes `core` independent of
how fast mypy is on the newest Python.

### Phase 2: restructure CI (43 → about 26 jobs per PR, one check per category)

A note on what job count does and doesn't buy. Jobs run in parallel, so **cutting jobs
mostly saves runner minutes and cache contention, not wall time**. The wall-time win comes
from Phase 0 (one slow job). That leaves room to keep one visible check per category:

| Job | Pythons on PRs | Contents |
|---|---|---|
| `lint`, `typecheck` | 3.13 | unchanged (seconds). Don't let `lint` cancel `typecheck`/`docs` (`fail-fast: false` on `others`), so contributors see every problem in one round. |
| **`core`** | **3.10–3.14 (all)** | `pytest test --ignore=test/contrib`, xdist, coverage sysmon. The most important signal, so it keeps the full Python matrix. |
| `<category>` (`contrib`, `aws`, `apache`, `gcloud` (mocked), `unixsocket`, `azureblob`, `mysql`, `postgres`) | oldest + newest (3.10, 3.14) | one job per category, as today: `pytest test/contrib -m <category>`. Check names stay `aws (py310)`, `gcloud (py314)`, etc. MySQL and Azurite become `services:` containers with health checks (as Postgres already is), replacing the init.d MySQL setup and the `docker run` Azurite race. |
| `docs` | 3.13 | path-filterable |
| `coverage` | | combine artifacts, **one** Codecov upload + junit for Test Analytics (spotify/luigi#3346), tagged by category so flaky/slow reports are grouped the same way; informational |
| `selection-audit` | 3.13 | §1.2; seconds |

That's 5 `core` + 16 category + 5 other ≈ **26 jobs**, down from 43, with every
category still reported on its own. If runner minutes ever matter more than check
names, a fallback is one job per Python with **one step per category** (with
`if: ${{ !cancelled() }}` so every step runs). The failing category is then visible as a
step name in the job, at about 12 jobs total.

**Nightly and on push to `master`:**
- every category on every Python (the full matrix);
- `pytest -p randomly` on `core` (order-dependency detection);
- `slow` tests, if any;
- credential-requiring jobs (`gcloud`, `dropbox`) if the org provides secrets;
- an auto-filed issue on failure.

### Phase 3: keep it fast (ongoing)

- A `slow` marker plus `pytest -m "not slow" -n auto` as the documented inner loop.
- `--durations=25` in CI logs; nightly fails if a unit test takes over 5s without `slow`.
- Modernize the very old pins. Each one is a source of compile time, warnings, or dead
  tests: `pymongo==3.4.0`, `psutil<4.0`, `mock<2.0`, `moto<5`, `HTTPretty==0.8.10`,
  `sqlalchemy<1.4`, `selenium==3.0.2`, `coverage<6`, `boto` 2.
- **Let Renovate/Dependabot update `uv.lock`.** The root cause of §3.1 is a lockfile that
  quietly fell behind a new Python. Dependabot supports `uv` lockfiles.
- Migrate to pytest style gradually: new tests use fixtures; old tests convert when they
  are touched.
- Review the top-5 flaky and top-5 slow tests (Codecov Test Analytics) once per release.

---

## 6. Expected impact

| Metric | Today (upstream) | After Phase 0 | After Phases 1–2 |
|---|---:|---:|---:|
| PR wall time (successful run) | **17–32 min** | **~5–6 min** | ~3–4 min‡ |
| Longest job | py314-core 17.5–25.4 min | ~2–5 min | ~2 min‡ |
| Runner time per run | 1h13m–1h27m | ~50–60 min‡ | ~30–35 min‡ |
| Jobs per PR | 43 | 43 | ~26 (one check per category kept) |
| Tests never run in CI (§3.5 #1–#7) | ≈150+ | ≈145 | 0 unexplained (rest marked `manual` with a reason) |
| Local `core`, serial, no CI skips | 391s, 27 failures | ~150s, 0–3 failures | < 60s‡ |
| Known flake sources | ports, sleeps, wall-clock, registry leak | unchanged | addressed |

‡ estimates. Everything else is measured or read from upstream CI.

---

## 7. Risks and trade-offs

- **Bumping mypy** could change what the plugin sees. `mypy_test.py` passes on 1.18.2,
  but the `typecheck` env (`mypy luigi/`) may report new errors, which might need fixing
  in the same PR.
- **The coverage 5 → 7 upgrade** may shift percentages; codecov targets may need a
  one-time adjustment.
- **Path-based `core`** requires moving the 5 `unixsocket` tests (or allow-listing them)
  and adding markers to 32 unmarked contrib tests. Both are small and mechanical, and the
  collection hook enforces the rule from then on.
- **Running categories on only the oldest and newest Python on PRs** could miss a
  regression specific to a middle version in, say, `aws`. `core` still runs on all
  versions, and the nightly full matrix catches the rest.
- **The selection audit and un-skipping** will expose broken tests, and possibly real
  bugs. Budget for triage.
- **`pytest-socket`** will flag tests that quietly use the network. Roll it out on
  `core` first.

## 8. Open questions for maintainers

1. `unixsocket`: move into `core` (adding `requests-unixsocket` to the core
   dependencies), or keep it as a category?
2. Category jobs on PRs: oldest + newest Python (≈26 jobs, one check per category), or
   one job per Python with a step per category (≈12 jobs)?
3. `gcloud`/`dropbox` real-service tests: is there appetite for org secrets in a nightly
   job, or should they stay `requires_credentials` (not run in CI)?
4. Untested contrib modules (`mongodb`, `redis_store`, `kubernetes`, `esindex`, webhdfs):
   revive their tests, or deprecate the modules?
5. Should Codecov stay a required check, or become informational?
6. Adopt Codecov Test Analytics (spotify/luigi#3346), and Dependabot for `uv.lock`?
7. Quarantine expiry: is "two releases, then delete" acceptable?

## 9. Suggested PR sequence

1. **mypy lockfile bump** (0.1): one line, about −20 min per PR.
2. Coverage 7 + sysmon (0.2) and `rpc-retry-wait: 0` (0.3).
3. Workflow hygiene (0.4–0.6).
4. Dead envs and scripts (0.8), nose-named tests + `_ServerTest` (0.7).
5. Local DX + CONTRIBUTING (0.9–0.10).
6. Path-based `core` + one-category-per-contrib-test hook + selection audit (1.1–1.2),
   then resolve the dead tests (1.3), one PR per module.
7. `running_luigid`, `wait_until`, wall-clock assertions, performance guard tests rewritten
   to check scaling, and state fixes (1.4–1.7).
8. Network blocking, quarantine, and moving `mypy_test` (1.8–1.10).
9. CI restructure + nightly (Phase 2).
10. Phase 3, ongoing.

---

## Appendix A: Reproduction

```bash
git clone https://github.com/spotify/luigi && cd luigi
export LUIGI_CONFIG_PATH=$PWD/test/testconfig/luigi.cfg AWS_DEFAULT_REGION=us-east-1 \
       AWS_ACCESS_KEY_ID=accesskey AWS_SECRET_ACCESS_KEY=secretkey LC_ALL=C.UTF-8 \
       GITHUB_ACTIONS=true COVERAGE_PROCESS_START=$PWD/.coveragerc
M='not minicluster and not gcloud and not mysql and not postgres and not unixsocket and not contrib and not apache and not aws and not azureblob and not dropbox'

# py314-core as CI runs it (mypy 1.14.1 from uv.lock, coverage 5.5): ~18 min
UV_PROJECT_ENVIRONMENT=.venv-3.14 uv sync --python 3.14 --no-default-groups --group common
PATH=$PWD/.venv-3.14/bin:$PATH python test/runtests.py --doctest-modules -m "$M" -n auto --dist=loadfile --durations=15

# Is mypy compiled?
.venv-3.14/bin/python -c "import mypy,os; print(any(f.endswith('.so') for f in os.listdir(os.path.dirname(mypy.__file__))))"

# Fix 1: compiled mypy (~2 min)
uv pip install --python .venv-3.14 "mypy==1.18.2"
PATH=$PWD/.venv-3.14/bin:$PATH python test/runtests.py --doctest-modules -m "$M" -n auto --dist=loadfile

# Fix 2: + coverage 7 with sys.monitoring (~1 min)
uv pip install --python .venv-3.14 "coverage>=7.6"
COVERAGE_CORE=sysmon PATH=$PWD/.venv-3.14/bin:$PATH python test/runtests.py --doctest-modules -m "$M" -n auto --dist=loadfile

# Import-time module skips (invisible in normal output)
python -m pytest --collect-only -q --no-cov -rs | grep ^SKIPPED

# Nose-named methods pytest never collects
grep -rnE "^\s+def [a-z_]+_test\(self" test --include=*.py
```

The selection map (§3.5) was produced with a 6-line plugin that writes
`{"id": item.nodeid, "marks": [...]}` for every item in `pytest_collection_finish`,
followed by evaluating each tox env's `-m` expression and path against it. That's the
same approach proposed for the CI selection audit (§1.2).

## Appendix B: Raw measurements

| Run | Result |
|---|---|
| Upstream `Build` history | 326 runs, 106 failed; successful runs 16m51s–32m27s |
| Upstream per-job (3 runs) | see §3.1; py314-core 24m47s / 17m34s / 25m22s |
| Local py310 `core`, cov 5.5 (C tracer) | 1514 passed, 111s |
| Local py314 `core`, no coverage, mypy 1.14.1 | 181s (mypy tests ≈29s each) |
| Local py314 `core`, cov 5.5, mypy 1.14.1 | **1,104s** (mypy tests ≈205s each) |
| Local py314 `core`, cov 5.5, mypy 1.18.2 | **117s** |
| Local py314 `core`, cov 7 sysmon, mypy 1.18.2 | **62s** |
| Local py313 `core`, cov 5.5 / none / cov 7 ctrace / cov 7 sysmon | 92s / 46s / 57s / 48s |
| Local `server_test.py` with `rpc-retry-wait: 0` | 3.4s (vs 244s) |
| Local `contrib` / `aws` / `apache` / `scheduler` | 12s / 25s / 13s / 22s |
| `uv sync --group common` cold | 4s (3.13), 6s (3.10) |
| Collected tests (upstream, `common` deps) | 1,868; 24 module-level skips |

Every local `core` run also had 2 environment-specific failures (no `ssh` binary; psutil
3.4 child-wait timeout in the container). Both are deterministic, not intermittent.
