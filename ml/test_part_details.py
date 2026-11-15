"""Tests for part_details.py on the server's catalog fixtures: python3 -m unittest discover -s ml -p 'test_*.py'"""
import os
import unittest

from part_details import add_details, load_part_details

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures")


class PartDetailsTest(unittest.TestCase):
    def test_counts_one_inventory_per_set_most_common_first(self):
        details, colors = load_part_details(FIXTURES, ["3001"])
        # Inventory 11 is a second version of set 100-1 and is ignored, so its 99 black bricks do not count.
        self.assertEqual(details["3001"]["colors"], [[4, 2], [1, 1]])
        self.assertEqual(details["3001"]["name"], "Brick 2 x 4")
        self.assertEqual(details["3001"]["img"], "https://cdn.rebrickable.com/media/parts/elements/300121.jpg")
        self.assertEqual([c["id"] for c in colors], [1, 4])
        self.assertEqual(colors[1], {"id": 4, "name": "Red", "rgb": "C91A09", "isTrans": False})

    def test_spares_count_and_quoted_names_are_read(self):
        details, _ = load_part_details(FIXTURES, ["3069b", "3069bpr0001"])
        self.assertEqual(details["3069b"]["colors"], [[1, 1]])
        self.assertEqual(details["3069b"]["name"], "Tile 1 x 2 with Groove, plain")
        self.assertEqual(details["3069bpr0001"]["name"], 'Tile 1 x 2 with "Go" Print')
        self.assertIsNone(details["3069b"]["img"])

    def test_limit_and_unknown_parts(self):
        details, colors = load_part_details(FIXTURES, ["3001", "nope"], max_colors=1)
        self.assertEqual(details["3001"]["colors"], [[4, 2]])
        self.assertNotIn("nope", details)
        self.assertEqual([c["id"] for c in colors], [4])

    def test_add_details_keeps_existing_fields(self):
        classes = [{"partNum": "3020", "name": "Plate 2 x 4", "members": ["3020"], "sizeMm": [31.8, 15.8, 3.2]},
                   {"partNum": "nope", "name": "Nope", "members": [], "sizeMm": []}]
        colors = add_details(classes, FIXTURES)
        self.assertEqual(classes[0]["sizeMm"], [31.8, 15.8, 3.2])
        self.assertEqual(classes[0]["details"]["colors"], [[0, 1]])
        self.assertNotIn("details", classes[1])
        self.assertEqual([c["id"] for c in colors], [0])


if __name__ == "__main__":
    unittest.main()
