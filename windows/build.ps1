$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python -m pip install --disable-pip-version-check -r requirements-dev.txt
python -m pytest -q
$assets = "src/gaoyanjiu/assets;gaoyanjiu_assets"
python -m PyInstaller --noconfirm --clean --name GaoYanJiu-cli --console --onefile --paths src --add-data $assets --distpath dist --workpath build/cli --specpath build/cli launch.py
python -m PyInstaller --noconfirm --clean --name GaoYanJiu --windowed --onefile --paths src --add-data $assets --distpath dist --workpath build/gui --specpath build/gui launch.py
Get-ChildItem dist\*.exe | ForEach-Object { Write-Output ("{0}`t{1}" -f $_.Name, $_.Length) }
