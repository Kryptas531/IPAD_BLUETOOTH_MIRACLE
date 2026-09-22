param(
    [string[]]$Stages = @("trackpad", "game", "direct-input", "deck"),
    [int]$MaxFixLoops = 2,
    [switch]$NoMerge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoSlug = "Kryptas531/IPAD_BLUETOOTH_MIRACLE"
$WorkflowName = "Build unsigned IPA"

$StageMap = @{
    "trackpad" = @{
        Branch = "feat/trackpad-usability"
        Task = @"
Implement the next TRACKPAD usability slice from current SPEC §7, §8 and §9.
Audit KeyboardView, TrackpadPanel, TouchpadView and SettingsView first.
Improve only already-specified usability gaps: maximize useful landscape trackpad area, keep chrome compact, preserve 1-finger move, tap=LMB, 2-finger scroll, 2-finger tap=RMB and drag behavior, and inspect gesture interaction for obvious conflicts.
Preserve sensitivity settings, HID semantics and the GAME high-fidelity path.
Do not implement GAME, gyro, dictation, TOUCH absolute digitizer or unrelated cleanup.
"@
    }
    "game" = @{
        Branch = "feat/game-usability"
        Task = @"
Implement the next GAME usability slice from current SPEC §7, §8 and §9.
Audit the current GAME surface first.
Keep GAME near-fullscreen, keep controls/debug/settings temporary, preserve the existing raw/coalesced touch path, metrics, BLE mouse semantics and sensitivity behavior.
Do not implement Gyro/Hybrid behavior yet and do not touch protected BLE/HID files.
"@
    }
    "direct-input" = @{
        Branch = "feat/direct-input-usability"
        Task = @"
Implement the next Direct Input / Windows keyboard usability slice from current SPEC §7 and §8.
Audit DirectInputController, KeyboardView and SettingsView first.
Expose the already-specified compact capture/release UX through the keyboard indicator long-press and/or Settings, without changing physical keyboard/mouse forwarding semantics.
Preserve the configurable Ctrl+Alt+Backspace release chord.
Do not touch protected BLE/HID files and do not broaden scope.
"@
    }
    "deck" = @{
        Branch = "feat/deck-usability"
        Task = @"
Implement the next DECK usability slice from current SPEC §5, §7 and §8.
Audit DeckPanel first.
Preserve the canonical Windows 4x4 grid, page 1/page 2 shortcut semantics and temporary F1-F12 grid.
Polish only layout, compact navigation/page switching and immediate pressed feedback already required by the current spec.
Do not resurrect the legacy TV/media remote architecture and do not add unrelated shortcuts.
"@
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList
    )
    $output = & $FilePath @ArgumentList
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Command failed ($code): $FilePath $($ArgumentList -join ' ')$([Environment]::NewLine)$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Assert-TrackedClean {
    $status = (& git status --porcelain=v1 --untracked-files=no) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "git status failed: $status" }
    if ($status.Trim()) {
        throw "Tracked worktree is not clean. Autopilot will not touch it:$([Environment]::NewLine)$status"
    }
}

function Sync-Main {
    Assert-TrackedClean
    Invoke-Checked git @("fetch", "--prune", "origin") | Out-Null
    Invoke-Checked git @("switch", "main") | Out-Null
    Invoke-Checked git @("pull", "--ff-only", "origin", "main") | Out-Null
    Assert-TrackedClean
}

function Get-OpenPrForBranch {
    param([string]$Branch)
    $raw = (Invoke-Checked $script:Gh @(
        "pr", "list", "--repo", $RepoSlug, "--state", "open",
        "--head", $Branch,
        "--json", "number,headRefOid,url,baseRefName",
        "--limit", "1"
    )) -join [Environment]::NewLine
    if (-not $raw.Trim()) { return $null }
    $items = @($raw | ConvertFrom-Json)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Wait-ForOpenPr {
    param([string]$Branch, [int]$Seconds = 90)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $pr = Get-OpenPrForBranch $Branch
        if ($null -ne $pr) { return $pr }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-PrData {
    param([int]$PrNumber)
    $raw = (Invoke-Checked $script:Gh @(
        "pr", "view", "$PrNumber", "--repo", $RepoSlug,
        "--json", "number,state,mergeable,headRefOid,headRefName,baseRefOid,baseRefName,files,url"
    )) -join [Environment]::NewLine
    return $raw | ConvertFrom-Json
}

function Assert-NoProtectedFiles {
    param($PrData)
    $paths = @($PrData.files | ForEach-Object { $_.path })
    $bad = @($paths | Where-Object {
        $_ -like "BTRemote/LowEnergy/*" -or
        $_ -like "BTRemote/Classic/*" -or
        $_ -eq "BTRemote/HIDInput.swift" -or
        $_ -eq "BTRemote/HIDReports.swift" -or
        $_ -eq "BTRemote/Info.plist" -or
        $_ -eq "BTRemote/entitlements.plist"
    })
    if ($bad.Count -gt 0) {
        throw "Protected files changed. Autopilot stops:$([Environment]::NewLine)$($bad -join [Environment]::NewLine)"
    }
}

function Assert-GreenCi {
    param([string]$HeadSha)
    $raw = (Invoke-Checked $script:Gh @(
        "run", "list", "--repo", $RepoSlug,
        "--commit", $HeadSha,
        "--workflow", $WorkflowName,
        "--json", "databaseId,status,conclusion,headSha,url,createdAt",
        "--limit", "20"
    )) -join [Environment]::NewLine
    $runs = @($raw | ConvertFrom-Json)
    $green = @($runs | Where-Object {
        $_.headSha -eq $HeadSha -and $_.status -eq "completed" -and $_.conclusion -eq "success"
    } | Sort-Object createdAt -Descending)
    if ($green.Count -eq 0) {
        $summary = @($runs | ForEach-Object {
            "$($_.databaseId) $($_.status) $($_.conclusion) $($_.headSha)"
        }) -join [Environment]::NewLine
        throw "No GREEN '$WorkflowName' run found for exact HEAD $HeadSha.$([Environment]::NewLine)$summary"
    }
    return $green[0]
}

function Invoke-QwenFresh {
    param(
        [string]$Prompt,
        [string]$LogPath
    )
    Write-Host "Starting fresh Qwen process -> $LogPath"
    $lines = & $script:Qwen $Prompt --yolo --max-tool-calls 100 --max-session-turns 50 --max-wall-time 45m |
        Tee-Object -FilePath $LogPath
    $code = $LASTEXITCODE
    $text = @($lines) -join [Environment]::NewLine
    if ($code -ne 0) {
        throw "Fresh Qwen process failed ($code). See $LogPath"
    }
    return $text
}

function Render-Command {
    param([string]$Path, [string]$ArgsText)
    $template = Get-Content -LiteralPath $Path -Raw
    return $template.Replace("{{args}}", $ArgsText)
}

function Invoke-Builder {
    param([string]$StageName, [string]$Branch, [string]$Task)
    $argsText = @"
$Task

AUTOPILOT CONTRACT:
- Work from current verified origin/main.
- Use EXACT branch name: $Branch
- One focused PR for this stage only.
- Do not touch protected BLE/HID boundaries.
- Run the canonical GitHub Actions '$WorkflowName' on the exact final HEAD and wait for GREEN.
- If inspection proves the stage is already fully compliant and no code/spec change is needed, do not invent a change and end with exactly: AUTOPILOT_STAGE: SKIP
- Otherwise open/update the PR and end with exactly: AUTOPILOT_STAGE: READY
- Do not review and do not merge.
"@
    $prompt = Render-Command ".qwen/commands/build.md" $argsText
    $log = Join-Path $script:LogDir "$StageName-builder.log"
    return Invoke-QwenFresh $prompt $log
}

function Invoke-Reviewer {
    param([string]$StageName, [int]$PrNumber, [string]$HeadSha, [int]$Attempt)
    $profile = Get-Content -LiteralPath ".qwen/agents/reviewer.md" -Raw
    $prompt = @"
You are the fresh independent final-review session itself.

The reviewer profile below is instruction text only. Ignore its YAML model-routing frontmatter.
Do NOT spawn another reviewer subagent. Use the current inherited project MEDIUM route.
Do not edit files.

Review live PR #$PrNumber at exact expected HEAD $HeadSha.
Independently inspect the live PR, current SPEC.md, AGENTS.md, QWEN.md, changed files/diff, relevant implementation and exact-head CI.
Builder prose is not proof.
If PR HEAD changed from $HeadSha, do not PASS.

Your final answer MUST contain exactly one verdict line:
REVIEW: PASS
or
REVIEW: CHANGES REQUIRED

After the verdict, list concrete findings. Do not merge.

REVIEWER PROFILE:
$profile
"@
    $log = Join-Path $script:LogDir "$StageName-review-$Attempt.log"
    return Invoke-QwenFresh $prompt $log
}

function Invoke-Fixer {
    param([string]$StageName, [int]$PrNumber, [string]$ReviewText, [int]$Attempt)
    $argsText = @"
PR #$PrNumber

Concrete fresh-review output:
$ReviewText

AUTOPILOT CONTRACT:
- Fix only current concrete findings.
- Keep the existing PR branch.
- Do not force-push.
- Run '$WorkflowName' on the exact new HEAD and wait for GREEN.
- Do not invoke final review and do not merge.
"@
    $prompt = Render-Command ".qwen/commands/fix-review.md" $argsText
    $log = Join-Path $script:LogDir "$StageName-fix-$Attempt.log"
    return Invoke-QwenFresh $prompt $log
}

function Merge-Stage {
    param([int]$PrNumber, [string]$ExpectedHead, [string]$ExpectedBase, [string]$Branch)
    $pr = Get-PrData $PrNumber
    if ($pr.state -ne "OPEN") { throw "PR #$PrNumber is not OPEN." }
    if ($pr.headRefOid -ne $ExpectedHead) { throw "PR #$PrNumber HEAD moved before merge." }
    if ($pr.baseRefOid -ne $ExpectedBase) { throw "PR #$PrNumber base moved before merge." }
    if ($pr.mergeable -ne "MERGEABLE") { throw "PR #$PrNumber is not mergeable: $($pr.mergeable)" }
    Assert-NoProtectedFiles $pr
    $ci = Assert-GreenCi $ExpectedHead
    Write-Host "Merge gate OK: PR #$PrNumber, HEAD $ExpectedHead, CI $($ci.databaseId)"

    if ($NoMerge) {
        Write-Host "NoMerge set. Leaving PR #$PrNumber open."
        return
    }

    Invoke-Checked $script:Gh @("pr", "merge", "$PrNumber", "--repo", $RepoSlug, "--merge") | Out-Null
    Sync-Main

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git push origin --delete $Branch *> $null
        & git branch -D $Branch *> $null
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

$root = (& git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) { throw "Run this script inside the repository." }
$root = ($root -join "").Trim()
Set-Location $root

$QwenCmd = Get-Command qwen -ErrorAction SilentlyContinue
if ($null -eq $QwenCmd) { throw "qwen is not on PATH." }
$script:Qwen = $QwenCmd.Source

if (Test-Path "C:\LIFE\gh.exe") {
    $script:Gh = "C:\LIFE\gh.exe"
} else {
    $GhCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $GhCmd) { throw "GitHub CLI not found." }
    $script:Gh = $GhCmd.Source
}

$script:LogDir = Join-Path $root ".qwen\tmp\autopilot"
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null

Write-Host "Qwen autopilot starting in $root"
Write-Host "Stages: $($Stages -join ', ')"

foreach ($stageName in $Stages) {
    if (-not $StageMap.ContainsKey($stageName)) {
        throw "Unknown stage '$stageName'. Valid: $($StageMap.Keys -join ', ')"
    }

    $stage = $StageMap[$stageName]
    $branch = [string]$stage.Branch
    $task = [string]$stage.Task

    Write-Host ""
    Write-Host "=== STAGE: $stageName ==="
    Sync-Main

    $pr = Get-OpenPrForBranch $branch
    if ($null -eq $pr) {
        $builderOutput = Invoke-Builder $stageName $branch $task
        if ($builderOutput -match "(?m)^\s*AUTOPILOT_STAGE:\s*SKIP\s*$") {
            Write-Host "Stage '$stageName' reported already compliant. Continuing."
            Sync-Main
            continue
        }
        $pr = Wait-ForOpenPr $branch
        if ($null -eq $pr) {
            throw "Builder finished but no open PR found for branch '$branch'."
        }
    } else {
        Write-Host "Resuming existing PR #$($pr.number) for $branch"
    }

    $prNumber = [int]$pr.number
    $fixCount = 0
    $reviewAttempt = 0

    while ($true) {
        $prData = Get-PrData $prNumber
        if ($prData.state -ne "OPEN") { throw "PR #$prNumber is no longer open." }
        Assert-NoProtectedFiles $prData

        $headBeforeReview = [string]$prData.headRefOid
        $baseBeforeReview = [string]$prData.baseRefOid
        $ci = Assert-GreenCi $headBeforeReview
        Write-Host "Exact-head CI green: $($ci.databaseId) @ $headBeforeReview"

        Assert-TrackedClean
        $reviewAttempt++
        $reviewText = Invoke-Reviewer $stageName $prNumber $headBeforeReview $reviewAttempt
        Assert-TrackedClean

        $afterReview = Get-PrData $prNumber
        if ($afterReview.headRefOid -ne $headBeforeReview -or $afterReview.baseRefOid -ne $baseBeforeReview) {
            Write-Host "PR HEAD or base moved during review. Discarding stale review and re-running."
            continue
        }

        if ($reviewText -match "(?m)^\s*REVIEW:\s*PASS\s*$") {
            Merge-Stage $prNumber $headBeforeReview $baseBeforeReview $branch
            Write-Host "Stage '$stageName' complete."
            break
        }

        if ($reviewText -match "(?m)^\s*REVIEW:\s*CHANGES REQUIRED\s*$") {
            if ($fixCount -ge $MaxFixLoops) {
                throw "Stage '$stageName' exceeded MaxFixLoops=$MaxFixLoops. See review logs."
            }
            $fixCount++
            Invoke-Fixer $stageName $prNumber $reviewText $fixCount | Out-Null
            continue
        }

        throw "Reviewer returned no recognized verdict. See $script:LogDir"
    }
}

Write-Host ""
Write-Host "AUTOPILOT COMPLETE"
