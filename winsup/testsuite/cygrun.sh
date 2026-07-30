#!/bin/dash
#
# test driver to run $1 in the appropriate environment
#

# $1 = test executable to run
exe=$1

export PATH="$runtime_root:${PATH}"

if [ "$1" = "./mingw/cygload" ]
then
    windows_runtime_root=$(cygpath -m $runtime_root)
    # Keep MSYS2 from mangling the drive-qualified DLL path we pass to the
    # native cygload.  This must be exported: the MSYS2 runtime reads it from
    # this shell's own environment when converting arguments, so a per-command
    # "VAR=val cmd" prefix (which only sets it in the child) has no effect.
    export MSYS2_ARG_CONV_EXCL='*'
    $cygrun "$exe -v -cygwin $windows_runtime_root/msys-2.0.dll"
else
    cygdrop $cygrun $exe
fi
