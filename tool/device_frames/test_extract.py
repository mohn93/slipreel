# tool/device_frames/test_extract.py
import os, sys, unittest
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(__file__))
from extract import screen_rect  # noqa: E402

class ScreenRectTest(unittest.TestCase):
    def _fixture(self, path):
        # Opaque device body (200x400) with a transparent interior screen
        # rect at (20,30)-(180,370), plus transparent outer margin.
        img = Image.new("RGBA", (240, 440), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rectangle([20, 20, 220, 420], fill=(20, 20, 20, 255))   # body (opaque)
        d.rectangle([40, 50, 200, 390], fill=(0, 0, 0, 0))        # screen (cut-out)
        img.save(path)

    def test_finds_interior_screen_rect(self):
        p = "/tmp/_df_fixture.png"
        self._fixture(p)
        r = screen_rect(p)
        self.assertEqual(r["bezel_w"], 240)
        self.assertEqual(r["bezel_h"], 440)
        self.assertEqual(r["screen"]["w"], 161)   # 200-40+1
        self.assertEqual(r["screen"]["h"], 341)   # 390-50+1
        self.assertEqual(r["screen"]["x"], 40)
        self.assertEqual(r["screen"]["y"], 50)
        self.assertAlmostEqual(r["screenRect"]["l"], 40 / 240, places=4)

if __name__ == "__main__":
    unittest.main()
