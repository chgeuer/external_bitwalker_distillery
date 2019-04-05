function Get-Release-Apps {
    $vsn = $Env:REL_VSN
    # This pattern extracts the current release resource definition
    # RELEASES can contain one or more such definitions
    $pattern = "{{release,[^,]*,`"{0}`",[^,]*,[^\]]*,[^po]*(permanent|old)}}" -f $vsn
    $content = Get-Content -Raw -Path (join-path $Env:RELEASE_ROOT_DIR (join-path releases RELEASES))
    $release = Select-String -Pattern $pattern -InputObject $content -AllMatches | ForEach-Object { $_.Matches } | foreach { $_.Value }
    # This extracts the list of applications from the release resource
    $applications = Select-String -Pattern "\[([^\]]*)\]" -InputObject $release -AllMatches | ForEach-Object { $_.Matches } | foreach { $_.Groups[1] } | foreach { $_.Value }
    # This extracts each application from the list and builds a dictionary for use by the caller
    $libs = Select-String -Pattern "{(?<app>[^,]*),`"(?<vsn>[^`"]*)`",`"[^`"]*`"}" -InputObject $applications -AllMatches | foreach { $_.Matches }
    $libs | ForEach-Object { @{ "name" = $_.Groups["app"]; "vsn" = $_.Groups["vsn"] } }
}

function Format-Code-Path {
    param ($App = $(throw "You must provide App to Format-Code-Path!"))

    $erts_dir = (join-path $Env:ERTS_LIB_DIR $App["name"])
    $lib_dir = (join-path $Env:RELEASE_ROOT_DIR (join-path lib ("{0}-{1}" -f $App["name"],$App["vsn"])))
    if (test-path $erts_dir -PathType Container) {
        join-path $erts_dir ebin
    } elseif (test-path $lib_dir -PathType Container) {
        join-path $lib_dir ebin
    } else {
        log-error ("Could not locate code path for {0}" -f $App["name"])
    }
}

function Get-Code-Paths {
    get-release-apps | ForEach-Object { format-code-path -App $_ }
}

# Echoes the path to the current ERTS binaries, e.g. erl
function Get-ErtsBin {
    if (($null -eq $Env:ERTS_VSN) -or ($Env:ERTS_VSN -eq "")) {
        # Get-Command erl.exe | select-object -ExpandProperty Definition
        $(Get-Command erl.exe | Select-Object -ExpandProperty Definition | Get-Item).Directory.FullName
    } elseif (($null -eq $Env:USE_HOST_ERTS) -or ($Env:USE_HOST_ERTS -eq "")) {
        $erts_dir = (join-path $Env:RELEASE_ROOT_DIR ("erts-{0}" -f $Env:ERTS_VSN))
        if (Test-Path $erts_dir -PathType Container) {
            Join-Path $erts_dir bin
        } else {
            $Env:ERTS_DIR = ""
            Get-ErtsBin
        }
    } else {
        $Env:ERTS_DIR = ""
        Get-ErtsBin
    }
}

function Get-ErlArgs {
    $bin = Get-ErtsBin
    # Set flag for whether a boot script was provided by the caller
    $boot_provided = $false
    if ($args | select-string -Pattern "-boot" -SimpleMatch -Quiet) {
        $boot_provided = $true
    }
    # Set flag for whether the current erl is from a bundled ERTS
    $erts_included = $bin.StartsWith($Env:RELEASE_ROOT_DIR)
    $libs = (join-path $Env:RELEASE_ROOT_DIR lib)
    $config = @()
    if ($null -ne $Env:SYS_CONFIG_PATH) {
        $config = @("-config", $Env:SYS_CONFIG_PATH)
    }
    if ($erts_included -eq $true) {
        $Env:ERTS_LIB_DIR = $libs
        $codepaths = @("-pa")
    	$codepaths += get-code-paths
    } else {
        $codepaths = @()
    }
    $extra_codepaths = @()
    if ($null -ne $Env:CONSOLIDATED_DIR) {
        $extra_codepaths += @("-pa", $Env:CONSOLIDATED_DIR)
    }
    if ($null -ne $Env:EXTRA_CODE_PATHS) {
        $extra_codepaths += @("-pa", $Env:EXTRA_CODE_PATHS)
    }
    $base_args = @()
    if ($erts_included -and $boot_provided) {
        # Bundled ERTS with -boot set
        $base_args += @("-boot_var", "ERTS_LIB_DIR", $libs)
        $base_args += $config
        $base_args += $codepaths
        $base_args += $extra_codepaths
    } elseif ($erts_included) {
        # Bundled ERTS, using default boot script 'start_clean'
        # TODO: You forgot CONSOLIDATED_PATH here in the shell script
        $boot = (join-path $Env:RELEASE_ROOT_DIR (join-path bin start_clean))
        $base_args += @("-boot_var", "ERTS_LIB_DIR", $libs)
        $base_args += @("-boot", $boot)
        $base_args += $config
        $base_args += $codepaths
        $base_args += $extra_codepaths
    } elseif ($boot_provided -eq $false) {
        # Host ERTS with -boot not set
        $base_args += @("-boot", "start_clean")
        $base_args += $config
        $base_args += $codepaths
        $base_args += $extra_codepaths
    } elseif ($null -eq $Env:ERTS_LIB_DIR) {
        # Host ERTS, -boot set, no ERTS_LIB_DIR available
        $base_args += $config
        $base_args += $codepaths
        $base_args += $extra_codepaths
    } else {
        # Host ERTS, -boot set, ERTS_LIB_DIR available
        $base_args += @("-boot_var", "ERTS_LIB_DIR", $libs)
        $base_args += $config
        $base_args += $codepaths
        $base_args += $extra_codepaths
    }
    $base_args
}

# Invokes erl with the provided arguments
function Run-Erl {
    $bin = Get-ErtsBin
    if (($null -eq $bin) -or ($bin -eq "")) {
        log-error "Erlang runtime not found. If Erlang is installed, ensure it is in your PATH"
    }
    if (($IsWindows -eq $true) -or (($null -eq $IsWindows) -and ($env:OS -like "Windows*"))) {
        $erl = (Join-Path $bin "erl.exe")
    } else {
        $erl = (Join-Path $bin "erl")
    }
    $base_args = Get-ErlArgs @args

    & "$erl" @base_args @args
}

# Run Elixir
function Run-Elixir {
    if (($args.Length -eq 0) -or ($args[0] -eq "--help") -or ($args[0] -eq "-h")) {
        write-host @"
        Usage: elixir [options] [.exs file] [data]

        -e COMMAND                  Evaluates the given command (*)
        -r FILE                     Requires the given files/patterns (*)
        -S SCRIPT                   Finds and executes the given script in PATH
        -pr FILE                    Requires the given files/patterns in parallel (*)
        -pa PATH                    Prepends the given path to Erlang code path (*)
        -pz PATH                    Appends the given path to Erlang code path (*)

        --app APP                   Starts the given app and its dependencies (*)
        --cookie COOKIE             Sets a cookie for this distributed node
        --detached                  Starts the Erlang VM detached from console
        --erl SWITCHES              Switches to be passed down to Erlang (*)
        --help, -h                  Prints this message and exits
        --hidden                    Makes a hidden node
        --logger-otp-reports BOOL   Enables or disables OTP reporting
        --logger-sasl-reports BOOL  Enables or disables SASL reporting
        --name NAME                 Makes and assigns a name to the distributed node
        --no-halt                   Does not halt the Erlang VM after execution
        --sname NAME                Makes and assigns a short name to the distributed node
        --version, -v               Prints Elixir version and exits
        --werl                      Uses Erlang's Windows shell GUI (Windows only)

        ** Options marked with (*) can be given more than once
        ** Options given after the .exs file or -- are passed down to the executed code
        ** Options can be passed to the Erlang runtime using ELIXIR_ERL_OPTIONS or --erl"
"@
        exit
    }
    $mode = "elixir"
    $count = $args.Length
    $i = 0
    $erl_opts = @()
    $ex_opts = @()
    $extra_args = @()
    while ($i -lt $args.Length) {
        $arg = $args[$i]
        $i++
        switch ($arg) {
            "+elixirc" { $mode = "elixirc" }
            "-e" { 
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "-r" {
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "-pr" { 
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "-pa" {
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "-pz" {
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "--remsh" {
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "--app" {
                $val = $args[$i]
                $i++
                $ex_opts += @($arg, $val)
            }
            "--detached" { $erl_opts += "-detached" }
            "--hidden" { $erl_opts += "-hidden" }
            "--cookie" { 
                $val = $args[$i]
                $i++
                $erl_opts += @("-setcookie", ("`"{0}`"" -f $val))
            }
            "--sname" { 
                $val = $args[$i]
                $i++
                $erl_opts += @("-sname", ("`"{0}`"" -f $val))
            }
            "--name" { 
                $val = $args[$i]
                $i++
                $erl_opts += @("-name", ("`"{0}`"" -f $val))
            }
            "--logger-otp-reports" { 
                $val = $args[$i]
                $i++
                $erl_opts += @("-logger", "handle_otp_reports", $val)
            }
            "--logger-sasl-reports" { 
                $val = $args[$i]
                $i++
                $erl_opts += @("-logger", "handle_sasl_reports", $val)
            }
            "--erl" { 
                $val = $args[$i]
                $i++
                $opts = string-to-argv -String $val
                $erl_opts += $opts
            }
            default {
                $extra_args += $arg
            }
        }
    }
    Run-Erl -noshell -s elixir start_cli @erl_opts -extra @ex_opts @extra_args
}

# Run IEx
function iex {
    $bin = Get-ErtsBin
    if (($null -eq $bin) -or ($bin -eq "")) {
        log-error "Erlang runtime not found. If Erlang is installed, ensure it is in your PATH"
    }
    $werl = (join-path $bin werl)
    $base_args = Get-ErlArgs
    & $werl @base_args -user Elixir.IEx.CLI -extra --no-halt +iex @args
}

# Echoes the current ERTS version
function Erts-vsn {
    Run-Erl -noshell `
        -eval "Ver = erlang:system_info(version), io:format(`"~s~n`", [Ver])" `
        -s erlang halt
}

# Echoes the current ERTS root directory
function Erts-Root {
    Run-Erl -noshell `
        -eval "io:format(`"~s~n`", [code:root_dir()])." `
        -s erlang halt
}

# Echoes the current OTP version
function Otp-Vsn {
    Run-Erl -noshell `
        -eval "Ver = erlang:system_info(otp_release), io:format(`"~s~n`", [Ver])" `
        -s erlang halt
}

# Use release_ctl for local operations
# Use like `release_ctl eval "IO.puts(\"Hi!\")"`
function Release-Ctl {
    Run-Elixir -e "Mix.Releases.Runtime.Control.main" --logger-sasl-reports false "--" @args
}

# Use release_ctl for remote operations
# Use like `release_remote_ctl ping`
function Release-Remote-Ctl {
    require-cookie

    $name = $Env:PEERNAME
    if ($null -eq $name) {
        $name = $Env:NAME
    }
    $cookie = $Env:COOKIE
    $command, $args = $args
    Run-Elixir -e "Mix.Releases.Runtime.Control.main" `
           --logger-sasl-reports false `
           -- `
           $command `
           --name="$name" `
           --cookie="$cookie" `
           @args
}

# Run an escript in the node's environment
# Use like `escript "path/to/escript"`
function Escript {
    $scriptpath, $args = $args
    $bin = Get-ErtsBin
    $escript = (join-path $bin escript)
    & $escript (join-path $Env:ROOTDIR $scriptpath) @args
}

# Test erl to make sure it works, extract key info about runtime while doing so
$output = Run-Erl -noshell -eval "io:format(\`"~s~n~s~n\`", [code:root_dir(), erlang:system_info(version)])." -s erlang halt
if (($LastExitCode -ne 0) -or (!$?)) {
    log-error "Unusable Erlang runtime system! This is likely due to being compiled for another system than the host is running"
}
$rootdir, $erts_vsn = $output

# Set up ERTS environment
$Env:ROOTDIR = $rootdir
if ($null -eq $Env:ERTS_VSN) {
    # Update start_erl.data
    $Env:ERTS_VSN = $erts_vsn
    Set-Content -Path $Env:START_ERL_DATA -Value ("{0} {1}" -f $erts_vsn,$Env:REL_VSN)
} else {
    $Env:ERTS_VSN = $erts_vsn
}
$Env:ERTS_DIR = (join-path $rootdir ("erts-{0}" -f $Env:ERTS_VSN))
$Env:BINDIR = (join-path $Env:ERTS_DIR bin)
$Env:ERTS_LIB_DIR = (resolve-path (join-path $Env:ERTS_DIR (join-path ".." lib)))
$Env:LD_LIBRARY_PATH = ("{0}:{1}" -f $Env:ERTS_LIB_DIR,$Env:LD_LIBRARY_PATH)
$Env:EMU = "beam"
$Env:PROGNAME = "erl"
