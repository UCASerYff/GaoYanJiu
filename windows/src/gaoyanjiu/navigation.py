from __future__ import annotations


def resolve_navigation(section: str, scope: str) -> tuple[str, str]:
    """对齐 ResearchNavigationMigration：旧的状态页、归档页和项目页回到在投管理。"""
    if section == "changed":
        return "all", "changed"
    if section == "hidden":
        return "all", "hidden"
    if section == "projects":
        return "all", "all"
    return section, scope


def route_widget_target(target: str, section: str, scope: str) -> tuple[str, str]:
    if target == "submissions":
        return "all", "all"
    if target == "works":
        return "existing", scope
    return section, scope
