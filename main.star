#!/usr/bin/env lucicfg
# Copyright 2021 The Native Client Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

repo_path = "https://chromium.googlesource.com/native_client/src/native_client"
logo_path = \
    "https://storage.googleapis.com/chrome-infra-public/logo/nacl-logo.png"
service_account_domain = "chops-service-accounts.iam.gserviceaccount.com"
cipd_package = \
    "infra/recipe_bundles/chromium.googlesource.com/chromium/tools/build"

# Enable LUCI Realms support.
lucicfg.enable_experiment("crbug.com/1085650")

# Launch 100% of Swarming tasks for builds in "realms-aware mode"
luci.builder.defaults.experiments.set({"luci.use_realms": 100})

# Tell lucicfg what files it is allowed to touch
lucicfg.config(
    config_dir = "generated",
    tracked_files = [
        "commit-queue.cfg",
        "cr-buildbucket.cfg",
        "luci-logdog.cfg",
        "luci-milo.cfg",
        "luci-scheduler.cfg",
        "project.cfg",
        "realms.cfg",
    ],
    fail_on_warnings = True,
    lint_checks = [
        "default",
        "-confusing-name",
        "-function-docstring",
        "-function-docstring-args",
        "-function-docstring-return",
        "-function-docstring-header",
        "-module-docstring",
    ],
)

luci.project(
    name = "nacl",
    buildbucket = "cr-buildbucket.appspot.com",
    logdog = "luci-logdog.appspot.com",
    milo = "luci-milo.appspot.com",
    scheduler = "luci-scheduler.appspot.com",
    swarming = "chromium-swarm.appspot.com",
    acls = [
        acl.entry(
            roles = [
                acl.LOGDOG_READER,
                acl.PROJECT_CONFIGS_READER,
                acl.BUILDBUCKET_READER,
                acl.SCHEDULER_READER,
            ],
            groups = "all",
        ),
        acl.entry(
            roles = acl.LOGDOG_WRITER,
            groups = "luci-logdog-chromium-writers",
        ),
        acl.entry(
            roles = [acl.BUILDBUCKET_OWNER, acl.SCHEDULER_OWNER],
            groups = "project-nacl-admins",
        ),
        acl.entry(
            roles = acl.CQ_COMMITTER,
            groups = "project-nacl-committers",
        ),
        acl.entry(
            roles = acl.CQ_DRY_RUNNER,
            groups = "project-nacl-tryjob-access",
        ),
    ],
)

# Allow troopers and NaCl admins to use LED on all builders and inside
# toolchain pool.
# NOTE: The try & ci builders are using shared luci.flex.try&ci pools,
# which are configured elsewhere.
luci.realm(
    name = "pools/toolchain",
    bindings = [
        luci.binding(
            roles = "role/swarming.poolOwner",
            groups = "project-nacl-admins",
        ),
        luci.binding(
            roles = "role/swarming.poolViewer",
            groups = "all",
        ),
        luci.binding(
            roles = "role/swarming.poolUser",
            groups = "mdb/chrome-troopers",
        ),
    ],
)
luci.binding(
    realm = ["try", "ci"],
    roles = "role/swarming.taskTriggerer",
    groups = ["mdb/chrome-troopers", "project-nacl-admins"],
)

luci.logdog(gs_bucket = "chromium-luci-logdog")

luci.milo(logo = logo_path)

luci.bucket(name = "ci")
luci.bucket(name = "toolchain")
luci.bucket(
    name = "try",
    acls = [
        acl.entry(
            roles = acl.BUILDBUCKET_TRIGGERER,
            groups = ["service-account-cq", "project-nacl-tryjob-access"],
        ),
    ],
)

luci.cq(
    submit_max_burst = 4,
    submit_burst_delay = 8 * time.minute,
    status_host = "chromium-cq-status.appspot.com",
)

luci.cq_group(
    watch = cq.refset(
        repo = repo_path,
        refs = ["refs/heads/main"],
    ),
    name = "nacl",
    retry_config = cq.retry_config(
        single_quota = 1,
        global_quota = 2,
        failure_weight = 1,
        transient_failure_weight = 1,
        timeout_weight = 2,
    ),
)

luci.console_view(
    name = "main",
    repo = repo_path,
    title = "NaCl Main Console",
)
luci.console_view(
    name = "toolchain",
    repo = repo_path,
    title = "NaCl Toolchain Console",
)
luci.list_view(
    name = "try",
    title = "NaCl Try Builders",
)

def nacl_builder(
        name,
        dimension_mixins,
        bucket,
        service_account,
        dimension_pool,
        builder_group,
        slavetype):
    caches = []
    dimensions = {"cores": "8", "cpu": "x86-64", "pool": dimension_pool}
    properties = {
        "slavetype": slavetype,
        "builder_group": builder_group,
        "$build/goma": {
            "server_host": "goma.chromium.org",
            "enable_ats": True,
            "rpc_extra_params": "?prod",
        },
        "$recipe_engine/isolated": {
            "server": "https://isolateserver.appspot.com",
        },
        "$recipe_engine/swarming": {
            "server": "https://chromium-swarm.appspot.com",
        },
    }
    if "linux" in dimension_mixins:
        dimensions["os"] = "Ubuntu-16.04"
    elif "mac" in dimension_mixins:
        dimensions.pop("cores", None)  # Macs can be 4 or 8 cores
        dimensions["os"] = "Mac-10.15"
        caches = [swarming.cache(path = "osx_sdk", name = "osx_sdk")]
        properties["$build/goma"].pop("enable_ats", None)
    elif "win" in dimension_mixins:
        dimensions["os"] = "Windows-10"
    elif "win7" in dimension_mixins:
        dimensions["os"] = "Windows-7"

    if bucket == "toolchain":
        dimensions.pop("cores", None)
        properties.pop("$recipe_engine/isolated", None)
        properties.pop("$recipe_engine/swarming", None)

    if bucket == "try":
        properties["revision"] = "HEAD"

    execution_timeout = 3 * time.hour
    if "slow" in dimension_mixins:
        execution_timeout = 12 * time.hour

    recipe_name = "nacl"
    if name == "nacl-presubmit":
        recipe_name = "run_presubmit"
        properties["repo_name"] = "nacl"

    luci.builder(
        name = name,
        bucket = bucket,
        executable = luci.recipe(
            name = recipe_name,
            cipd_package = cipd_package,
            cipd_version = "refs/heads/main",
        ),
        service_account = service_account,
        caches = caches,
        execution_timeout = execution_timeout,
        dimensions = dimensions,
        build_numbers = True,
        properties = properties,
    )

def ci_builder(name, short_name, category, dimension_mixins):
    luci.console_view_entry(
        builder = name,
        console_view = "main",
        short_name = short_name,
        category = category,
    )
    luci.gitiles_poller(
        name = "master-gitiles-trigger",
        bucket = "ci",
        repo = repo_path,
        triggers = [name],
    )
    nacl_builder(
        name = name,
        dimension_mixins = dimension_mixins,
        bucket = "ci",
        service_account = "nacl-ci-builder@" + service_account_domain,
        dimension_pool = "luci.flex.ci",
        builder_group = "client.nacl",
        slavetype = "BuilderTester",
    )

def toolchain_builder(name, short_name, category, dimension_mixins):
    luci.console_view_entry(
        builder = name,
        console_view = "toolchain",
        short_name = short_name,
        category = category,
    )
    luci.gitiles_poller(
        name = "master-gitiles-trigger",
        bucket = "toolchain",
        repo = repo_path,
        triggers = [name],
    )
    nacl_builder(
        name = name,
        dimension_mixins = dimension_mixins,
        bucket = "toolchain",
        service_account = "nacl-toolchain-builder@" + service_account_domain,
        dimension_pool = "luci.nacl.toolchain",
        builder_group = "client.nacl.toolchain",
        slavetype = "BuilderTester",
    )

def try_builder(
        name,
        dimension_mixins,
        cq_type = "Normal",
        cq_disable_reuse = None):
    luci.list_view_entry(
        builder = name,
        list_view = "try",
    )

    location_regexp = None
    location_regexp_exclude = [".+/[+]/pnacl/.+", ".+/[+]/toolchain_build/.+"]
    if cq_type == "always":
        location_regexp_exclude = None
    elif cq_type == "toolchain":
        location_regexp = [
            ".+/[+]/build/.+",
            ".+/[+]/buildbot/.+",
            ".+/[+]/pnacl/.+",
            ".+/[+]/pynacl/.+",
            ".+/[+]/toolchain_build/.+",
        ]
        location_regexp_exclude = None
    luci.cq_tryjob_verifier(
        builder = name,
        cq_group = "nacl",
        location_regexp = location_regexp,
        location_regexp_exclude = location_regexp_exclude,
        disable_reuse = cq_disable_reuse,
    )

    nacl_builder(
        name = name,
        dimension_mixins = dimension_mixins,
        bucket = "try",
        service_account = "nacl-try-builder@" + service_account_domain,
        dimension_pool = "luci.flex.try",
        builder_group = "tryserver.nacl",
        slavetype = "Trybot",
    )

ci_builder(
    name = "linux-32-newlib-dbg",
    short_name = "32",
    category = "linux|newlib|dbg",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-newlib-dbg",
    short_name = "64",
    category = "linux|newlib|dbg",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-32-newlib-opt",
    short_name = "32",
    category = "linux|newlib|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-newlib-opt",
    short_name = "64",
    category = "linux|newlib|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-newlib-opt-test",
    short_name = "64",
    category = "linux|newlib|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-arm-newlib-opt",
    short_name = "arm",
    category = "linux|newlib|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-32-glibc-dbg",
    short_name = "32",
    category = "linux|glibc|dbg",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-glibc-dbg",
    short_name = "64",
    category = "linux|glibc|dbg",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-32-glibc-opt",
    short_name = "32",
    category = "linux|glibc|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-glibc-opt",
    short_name = "64",
    category = "linux|glibc|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-arm-glibc-opt",
    short_name = "arm",
    category = "linux|glibc|opt",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux-64-validator-opt",
    short_name = "validator",
    category = "linux",
    dimension_mixins = ["linux", "slow"],
)
ci_builder(
    name = "linux_64-newlib-dbg-asan",
    short_name = "asan",
    category = "linux",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-x86_64-pnacl",
    short_name = "64",
    category = "linux|pnacl|x86",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-x86_32-pnacl",
    short_name = "32",
    category = "linux|pnacl|x86",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-mips-pnacl",
    short_name = "mips",
    category = "linux|pnacl",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-arm_qemu-pnacl-dbg",
    short_name = "dbg",
    category = "linux|pnacl|arm",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-arm_qemu-pnacl-opt",
    short_name = "opt",
    category = "linux|pnacl|arm",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "mac-newlib-dbg",
    short_name = "dbg",
    category = "mac|newlib",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "mac-newlib-opt",
    short_name = "opt",
    category = "mac|newlib",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "mac-arm-newlib-opt",
    short_name = "arm",
    category = "mac|newlib",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "mac-glibc-dbg",
    short_name = "dbg",
    category = "mac|glibc",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "mac-glibc-opt",
    short_name = "opt",
    category = "mac|glibc",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "mac-newlib-opt-pnacl",
    short_name = "opt",
    category = "mac|pnacl",
    dimension_mixins = ["mac"],
)
ci_builder(
    name = "win7-64-arm-newlib-opt",
    short_name = "arm",
    category = "win|win7|newlib",
    dimension_mixins = ["win7"],
)
ci_builder(
    name = "win7-64-glibc-dbg",
    short_name = "dbg",
    category = "win|win7|glibc",
    dimension_mixins = ["win7"],
)
ci_builder(
    name = "win7-64-glibc-opt",
    short_name = "opt",
    category = "win|win7|glibc",
    dimension_mixins = ["win7"],
)
ci_builder(
    name = "win7-64-newlib-opt-pnacl",
    short_name = "opt",
    category = "win|win7|pnacl",
    dimension_mixins = ["win7"],
)
ci_builder(
    name = "win8-64-newlib-dbg",
    short_name = "dbg",
    category = "win|win10|newlib",
    dimension_mixins = ["win"],
)
ci_builder(
    name = "win8-64-newlib-opt",
    short_name = "opt",
    category = "win|win10|newlib",
    dimension_mixins = ["win"],
)
ci_builder(
    name = "linux_64-newlib-x86_32-pnacl-spec",
    short_name = "32",
    category = "spec|pnacl",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-x86_64-pnacl-spec",
    short_name = "64",
    category = "spec|pnacl",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-arm_qemu-pnacl-buildonly-spec",
    short_name = "arm",
    category = "spec|pnacl",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-x86_32-spec",
    short_name = "32",
    category = "spec|newlib",
    dimension_mixins = ["linux"],
)
ci_builder(
    name = "linux_64-newlib-x86_64-spec",
    short_name = "64",
    category = "spec|newlib",
    dimension_mixins = ["linux"],
)

toolchain_builder(
    name = "linux-pnacl-x86_64",
    short_name = "linux",
    category = "pnacl.release",
    dimension_mixins = ["linux", "slow"],
)
toolchain_builder(
    name = "mac-pnacl-x86_32",
    short_name = "mac",
    category = "pnacl.release",
    dimension_mixins = ["mac", "slow"],
)
toolchain_builder(
    name = "win-pnacl-x86_32",
    short_name = "win",
    category = "pnacl.release",
    dimension_mixins = ["win", "slow"],
)
toolchain_builder(
    name = "linux-pnacl-x86_64-tests-x86_32",
    short_name = "x86-32",
    category = "pnacl.fyi",
    dimension_mixins = ["linux", "slow"],
)
toolchain_builder(
    name = "linux-pnacl-x86_64-tests-x86_64",
    short_name = "x86-64",
    category = "pnacl.fyi",
    dimension_mixins = ["linux", "slow"],
)
toolchain_builder(
    name = "linux-pnacl-x86_32-tests-mips",
    short_name = "mips",
    category = "pnacl.fyi",
    dimension_mixins = ["linux"],
)
toolchain_builder(
    name = "linux-pnacl-x86_64-tests-arm",
    short_name = "arm",
    category = "pnacl.fyi",
    dimension_mixins = ["linux", "slow"],
)

try_builder(
    name = "nacl-arm_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-arm_perf",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-mac_arm_newlib_opt",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-mac_glibc_dbg",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-mac_glibc_opt",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-mac_newlib_dbg",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-mac_newlib_opt",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-mac_newlib_opt_pnacl",
    dimension_mixins = ["mac"],
)
try_builder(
    name = "nacl-precise32_glibc_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise32_newlib_dbg",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise32_newlib_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise64_arm_glibc_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise64_arm_newlib_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise64_glibc_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise64_newlib_dbg",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise64_newlib_opt",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-arm_qemu-pnacl",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-dbg-asan",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-mips-pnacl",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-x86_32-pnacl",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-x86_32-pnacl-spec",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-x86_64-pnacl",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-precise_64-newlib-x86_64-pnacl-spec",
    dimension_mixins = ["linux"],
)
try_builder(
    name = "nacl-presubmit",
    dimension_mixins = ["linux"],
    cq_type = None,
    cq_disable_reuse = True,
)
try_builder(
    name = "nacl-toolchain-linux-pnacl-x86_64",
    dimension_mixins = ["linux", "slow"],
    cq_type = "toolchain",
)
try_builder(
    name = "nacl-toolchain-mac-pnacl-x86_32",
    dimension_mixins = ["mac", "slow"],
    cq_type = "toolchain",
)
try_builder(
    name = "nacl-toolchain-win7-pnacl-x86_64",
    dimension_mixins = ["win", "slow"],
    cq_type = "toolchain",
)
try_builder(
    name = "nacl-win32_glibc_opt",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win32_newlib_opt",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win64_glibc_opt",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win64_newlib_dbg",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win64_newlib_opt",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win7_64_arm_newlib_opt",
    dimension_mixins = ["win7"],
)
try_builder(
    name = "nacl-win7_64_newlib_opt_pnacl",
    dimension_mixins = ["win7"],
)
try_builder(
    name = "nacl-win8-64_newlib_dbg",
    dimension_mixins = ["win"],
)
try_builder(
    name = "nacl-win8-64_newlib_opt",
    dimension_mixins = ["win"],
)
