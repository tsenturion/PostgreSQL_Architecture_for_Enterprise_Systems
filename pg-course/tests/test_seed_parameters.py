"""Проверяет SQL-шаблоны psycopg2 без подключения к базе и запуска контейнеров."""
import ast
from pathlib import Path
import re
import unittest


class SeedParameterTests(unittest.TestCase):
    def test_parameterized_queries_have_no_unescaped_percent(self):
        source = Path(__file__).resolve().parents[1] / "scripts" / "seed.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        checked = 0
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            if node.func.attr != "execute" or len(node.args) < 2:
                continue
            query = node.args[0]
            if not isinstance(query, ast.Constant) or not isinstance(query.value, str):
                continue
            checked += 1
            with self.subTest(line=node.lineno):
                # При передаче параметров литеральный процент записывается как %%.
                remainder = re.sub(r"%%|%s|%\([A-Za-z_][A-Za-z_0-9]*\)s", "", query.value)
                self.assertNotIn("%", remainder, "Литеральный % конфликтует с параметрами psycopg2")
        self.assertGreaterEqual(checked, 3, "Не найдены ожидаемые параметризованные запросы наполнения")


if __name__ == "__main__":
    unittest.main()
