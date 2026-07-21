import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "rename_codemod",
    pathlib.Path(__file__).resolve().parents[2] / "scripts" / "rename_codemod.py")
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)


def test_content_module_vs_class_disambiguation():
    assert rc.transform_content("from Ragnar import Ragnar") == "from optaris_defense import OptarisDefense"
    assert rc.transform_content("import Ragnar") == "import optaris_defense"
    assert rc.transform_content("class Ragnar:") == "class OptarisDefense:"


def test_content_compound_identifiers():
    assert rc.transform_content("class RagnarMenu(Base):") == "class OptarisDefenseMenu(Base):"
    assert rc.transform_content("class PagerRagnar:") == "class PagerOptarisDefense:"
    assert rc.transform_content("def restart_ragnar_service():") == "def restart_optaris_defense_service():"
    assert rc.transform_content("import headlessRagnar") == "import headless_optaris_defense"


def test_content_services_paths_display_constants():
    assert rc.transform_content("/home/ragnar/Ragnar") == "/home/optaris-defense/OptarisDefense"
    assert rc.transform_content("ragnar.service") == "optaris-defense.service"
    assert rc.transform_content("ragnar-csi-fanout.service") == "optaris-defense-csi-fanout.service"
    assert rc.transform_content("Ragnar Cyberviking") == "OptarisDefense Cyberviking"
    assert rc.transform_content("RAGNAR_HOME") == "OPTARIS_DEFENSE_HOME"


def test_content_leaves_exclusions_untouched():
    assert rc.transform_content("OptarisSense sensing-server") == "OptarisSense sensing-server"
    assert rc.transform_content("optaris-edge host, Bjorn project") == "optaris-edge host, Bjorn project"


def test_transform_path():
    assert rc.transform_path("Ragnar.py") == "optaris_defense.py"
    assert rc.transform_path("headlessRagnar.py") == "headless_optaris_defense.py"
    assert rc.transform_path("install_ragnar.sh") == "install_optaris_defense.sh"
    assert rc.transform_path("web/ragnar.ico") == "web/optaris_defense.ico"
    assert rc.transform_path("config/systemd/ragnar-csi-fanout.service") == "config/systemd/optaris-defense-csi-fanout.service"
    assert rc.transform_path("scripts/install_sensing.sh") == "scripts/install_sensing.sh"


def test_transform_path_compound_pascal_module():
    assert rc.transform_path("pager/PagerRagnar.py") == "pager/PagerOptarisDefense.py"
    assert rc.transform_path("Ragnar.py") == "optaris_defense.py"
    assert rc.transform_path("headlessRagnar.py") == "headless_optaris_defense.py"
    assert rc.transform_path("install_ragnar.sh") == "install_optaris_defense.sh"
    assert rc.transform_path("config/systemd/ragnar-csi-fanout.service") == "config/systemd/optaris-defense-csi-fanout.service"


def test_transform_content_imports_match_paths():
    assert rc.transform_content("import PagerRagnar") == "import PagerOptarisDefense"
    assert rc.transform_content("importlib.import_module('PagerRagnar')") == "importlib.import_module('PagerOptarisDefense')"
