"""Целевые проверки сохранности повторной настройки и границ учебного стенда."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("course_configure", ROOT / "scripts" / "configure.py")
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    def make_home(self):
        temporary = tempfile.TemporaryDirectory(prefix="pg-course-test-")
        self.addCleanup(temporary.cleanup)
        home = Path(temporary.name) / "lab"
        configure.install(ROOT, home, permissions=False)
        return home

    def test_repeat_preserves_secrets_data_and_certificates(self):
        home = self.make_home()
        env = (home / ".env").read_bytes()
        original = (home / "compose.json").read_bytes()
        stamp = (home / "compose.json").stat().st_mtime_ns
        pgdata = home / "data" / "pg1" / str(configure.PG_MAJOR) / "docker"
        pgdata.mkdir(parents=True)
        (pgdata / "PG_VERSION").write_text(f"{configure.PG_MAJOR}\n", encoding="utf-8")
        sentinel = home / "data" / "pg1" / "учебные-данные"
        sentinel.write_bytes(b"existing-data")
        (home / "certs" / "server.key").write_bytes(b"existing-private-key")
        configure.install(ROOT, home, permissions=False)
        self.assertEqual((home / ".env").read_bytes(), env)
        self.assertEqual((home / "compose.json").read_bytes(), original)
        self.assertEqual((home / "compose.json").stat().st_mtime_ns, stamp)
        self.assertEqual(sentinel.read_bytes(), b"existing-data")
        self.assertEqual((home / "certs" / "server.key").read_bytes(), b"existing-private-key")

    def test_lost_secrets_do_not_get_replaced_for_existing_database(self):
        with tempfile.TemporaryDirectory(prefix="pg-course-lost-env-") as temporary:
            home = Path(temporary)
            data = home / "data" / "pg1" / str(configure.PG_MAJOR) / "docker"
            data.mkdir(parents=True)
            (data / "PG_VERSION").write_text(f"{configure.PG_MAJOR}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "утрачен"):
                configure.settings(home)
            self.assertFalse((home / ".env").exists())

    def test_changed_seed_size_is_rejected(self):
        home = self.make_home()
        with self.assertRaisesRegex(ValueError, "не пересоздаёт"):
            configure.settings(home, orders=10000)

    def test_loopback_and_optional_services(self):
        home = self.make_home()
        document = json.loads((home / "compose.json").read_text(encoding="utf-8"))
        services = document["services"]
        values = configure.read_env(home / ".env")
        self.assertEqual(values["BIND_ADDRESS"], "127.0.0.1")
        self.assertEqual(len([name for name in services if name.startswith("etcd")]), 3)
        for name in ("etcd1", "etcd2", "etcd3", "exporter1", "exporter2"):
            self.assertNotIn("ports", services[name])
        for name in ("prometheus", "grafana", "exporter1", "exporter2"):
            self.assertEqual(services[name]["profiles"], ["monitoring"])
        self.assertEqual(services["restore"]["profiles"], ["restore"])
        self.assertNotIn("upgrade", services)
        for name in ("pg1", "pg2"):
            self.assertIn("./data/restore:/restore", services[name]["volumes"])
            self.assertEqual(services[name]["mem_limit"], "512m")
        for service in services.values():
            self.assertEqual(service["logging"]["driver"], "none")
            self.assertFalse(any("ca.key" in volume for volume in service.get("volumes", [])))

    def test_distinct_pgdata_and_persistent_repo(self):
        home = self.make_home()
        services = json.loads((home / "compose.json").read_text(encoding="utf-8"))["services"]
        for name in ("pg1", "pg2", "restore"):
            self.assertIn(f"./data/{name}:/var/lib/postgresql", services[name]["volumes"])
            self.assertIn("./backups:/var/lib/pgbackrest", services[name]["volumes"])
            self.assertEqual(services[name]["environment"]["PGDATA"], configure.PGDATA)
        for name in ("pg1", "pg2"):
            patroni = json.loads((home / "config" / name / "patroni.json").read_text(encoding="utf-8"))
            self.assertEqual(patroni["postgresql"]["data_dir"], configure.PGDATA)
            self.assertIn(f"pg1-path={configure.PGDATA}\n", (home / "config" / name / "pgbackrest.conf").read_text(encoding="utf-8"))

    def test_versions_and_ports(self):
        home = self.make_home()
        services = json.loads((home / "compose.json").read_text(encoding="utf-8"))["services"]
        versions = json.loads((home / "versions.json").read_text(encoding="utf-8"))
        args = services["pg1"]["build"]["args"]
        for argument, key in (("POSTGRES_IMAGE", "postgres_image"), ("EXPORTER_IMAGE", "exporter_image"),
                              ("PATRONI_VERSION", "patroni_version"), ("PSYCOPG2_VERSION", "psycopg2_version"),
                              ("PGBACKREST_PACKAGE", "pgbackrest_package"), ("PGBOUNCER_PACKAGE", "pgbouncer_package")):
            self.assertEqual(args[argument], versions[key])
        for name, key in (("rw", "haproxy_image"), ("prometheus", "prometheus_image"), ("grafana", "grafana_image")):
            self.assertEqual(services[name]["image"], versions[key])
        expected = {"rw": ["5432:5432"], "pg1": ["5433:5432", "8008:8008"],
                    "pg2": ["5434:5432", "8009:8008"], "restore": ["5435:5432"],
                    "pool": ["6432:6432"], "grafana": ["3000:3000"], "prometheus": ["9090:9090"]}
        for name, ports in expected.items():
            self.assertEqual(services[name]["ports"], [f"${{BIND_ADDRESS}}:{port}" for port in ports])
        self.assertEqual(set(configure.PORTS), {int(port.split(":")[0]) for ports in expected.values() for port in ports})

    def test_lan_address_in_certificate_and_no_secrets_in_compose(self):
        home = self.make_home()
        self.assertIn("IP:192.168.0.35", (home / "certs" / "server.ext").read_text(encoding="utf-8"))
        text = (home / "compose.json").read_text(encoding="utf-8")
        for key in configure.PASSWORD_KEYS:
            self.assertNotIn(configure.read_env(home / ".env")[key], text)

    def test_changed_proxy_configuration_requires_reload(self):
        home = self.make_home()
        marker = home / "state" / "reload-proxy"
        self.assertFalse(marker.exists())
        (home / "config" / "proxy" / "haproxy.cfg").write_text("global\n", encoding="utf-8")
        configure.install(ROOT, home, permissions=False)
        self.assertTrue(marker.exists())
        configure.install(ROOT, home, permissions=False)
        self.assertTrue(marker.exists(), "Отметка должна сохраняться до применения конфигурации")


if __name__ == "__main__":
    unittest.main()
