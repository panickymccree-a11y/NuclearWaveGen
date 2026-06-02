@echo off
call D:\Vivado2020.2\Vivado\2020.2\settings64.bat
cd /d D:\Project\NuclearWaveGen\prj
echo Starting Vivado at %DATE% %TIME%
vivado -mode batch -source run_impl_cli.tcl -log vivado_timing_fix.log -journal vivado_timing_fix.jou
echo Vivado finished with exit code %ERRORLEVEL% at %DATE% %TIME%
