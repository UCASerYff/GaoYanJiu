import pytest

pytest.importorskip("msilib")

from smoke_install import require_data_dir


def test_bootstrap_data_directory_accepts_an_equivalent_windows_path(tmp_path):
    profile = tmp_path / "Research profile"
    profile.mkdir()
    child = tmp_path / "another directory"
    child.mkdir()
    alias = child / ".." / profile.name
    reported = str(alias.resolve(strict=True))

    assert str(alias) != reported
    require_data_dir(alias, reported)


def test_bootstrap_data_directory_distinguishes_missing_wrong_and_invalid_paths(tmp_path):
    profile = tmp_path / "Research profile"
    other = tmp_path / "different profile"
    profile.mkdir()
    other.mkdir()
    file = tmp_path / "not a directory"
    file.touch()

    with pytest.raises(AssertionError, match="different data directory"):
        require_data_dir(profile, str(other))
    with pytest.raises(AssertionError, match="Could not verify") as missing:
        require_data_dir(profile, str(tmp_path / "missing"))
    assert isinstance(missing.value.__cause__, FileNotFoundError)
    with pytest.raises(AssertionError, match="must both be directories"):
        require_data_dir(profile, str(file))
    with pytest.raises(AssertionError, match="must be an absolute path"):
        require_data_dir(profile, profile.name)
