@Echo off

if not exist ..\..\Units\Noisy\GUI md ..\..\Units\Noisy\GUI
if not exist ..\..\Bin\Noisy md ..\..\Bin\Noisy
if exist WinNoisy.cfg del WinNoisy.cfg

brcc32 WinNoisyW.rc || exit

dcc32.exe -B WinNoisy.dpr %* || exit