"""Write Windows PE product metadata and distribution notices."""

from __future__ import annotations

import sys
from importlib.metadata import distribution
from pathlib import Path

from gaoyanjiu import APP_NAME


def main(version: str, build: str, resource: Path, notices: Path) -> None:
    major, minor = (int(field) for field in version.split("."))
    full = (major, minor, int(build), 0)
    string_version = ".".join(str(part) for part in full)
    strings = {"CompanyName": "GaoSeries", "FileDescription": APP_NAME, "ProductName": APP_NAME,
               "FileVersion": string_version, "ProductVersion": version, "InternalName": "GaoYanJiu"}
    entries = ", ".join(f"StringStruct({name!r}, {value!r})" for name, value in strings.items())
    resource.write_text(
        "VSVersionInfo(\n"
        f"  ffi=FixedFileInfo(filevers={full}, prodvers={full}, mask=63, flags=0, OS=262148, "
        "fileType=1, subtype=0, date=(0, 0)),\n"
        f"  kids=[StringFileInfo([StringTable('080404b0', [{entries}])]), VarFileInfo([VarStruct('Translation', [2052, 1200])])])\n",
        encoding="utf-8",
    )
    base = Path(sys.base_prefix)
    bundled = [("Python runtime", base / "LICENSE.txt")]
    tcl_root = base / "tcl"
    for family in ("tcl", "tk"):
        license_path = next(tcl_root.glob(f"{family}*/license.terms"), None)
        if license_path is None and family == "tcl":
            # Some Python builds consolidate Tcl and Tk terms in the Tk tree.
            license_path = next(tcl_root.glob("tk*/license.terms"), None)
        if license_path is not None:
            bundled.append((family.title(), license_path))
    if len(bundled) == 1:
        raise RuntimeError("The Python Tcl/Tk distribution terms were not found")
    installer = distribution("PyInstaller")
    installer_license = next(path for path in installer.files or [] if path.name == "COPYING.txt")
    bundled.append(("PyInstaller bootloader", installer.locate_file(installer_license)))
    pdf = distribution("pypdf")
    pdf_license = next(path for path in pdf.files or [] if path.name == "LICENSE")
    bundled.append(("pypdf", pdf.locate_file(pdf_license)))
    notices.write_text("\n\n".join(f"{name}\n{'=' * len(name)}\n\n{path.read_text(encoding='utf-8')}"
                                    for name, path in bundled), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]))
