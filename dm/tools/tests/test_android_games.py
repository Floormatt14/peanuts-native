"""The games an APK carries by default: android/app/gradle.properties' nxGames is every game supported on Android, the profiles whose readiness.tsv has a status row
(dm/games/README.md "Readiness rows"), so a build made without -PnxGames never lacks one (a player's card once said "Could not prepare" for a game the APK did not have).
Each listed game has what build.gradle reads of it: game.tsv with build rows, and shader_map.tsv for Prepare's shaders.
A rung of the status ladder is a claim, so `playable` and `wip` must carry the evidence for it: a `tested` row naming the version, the phone(s) and the date."""
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PROPS = REPO / 'android/app/gradle.properties'
STATUSES = ('playable', 'wip', 'boots', 'bring-up')


def default_games():
    for line in PROPS.read_text(encoding='utf-8').splitlines():
        if line.startswith('nxGames='): return [g.strip() for g in line[len('nxGames='):].split(',') if g.strip()]
    return []


def status_rows(t):
    for line in t.read_text(encoding='utf-8').splitlines():
        c = line.split('\t')
        if len(c) >= 2 and c[0] == 'status': yield c[1].strip()


def android_profiles():
    out = set()
    for t in (REPO / 'dm/games').glob('*/readiness.tsv'):
        if any(s in STATUSES for s in status_rows(t)): out.add(t.parent.name)
    return out


class Games(unittest.TestCase):
    def test_every_supported_game_by_default(self):
        games = default_games()
        self.assertTrue(games, 'gradle.properties has no nxGames row')
        self.assertEqual(len(games), len(set(games)), 'a game twice in nxGames')
        self.assertEqual(set(games), android_profiles(), 'nxGames must be the profiles with a readiness.tsv status row')
        self.assertEqual(games[0], '040074A01BF12000', 'the first (the default game, the self-test\'s host) stays Donkey Kong Bananza')

    def test_listed_games_have_what_the_build_reads(self):
        for g in default_games():
            d = REPO / 'dm/games' / g
            self.assertTrue((d / 'game.tsv').is_file(), f'{g}: no game.tsv')
            self.assertTrue(any(l.startswith('build\t') for l in (d / 'game.tsv').read_text(encoding='utf-8').splitlines()), f'{g}: no build row (Prepare checks dumps against them)')
            self.assertTrue((d / 'shader_map.tsv').is_file(), f'{g}: no shader_map.tsv (Prepare builds its shaders from it)')

    def test_status_ladder(self):   # every status is one of the four rungs, one row a profile
        for t in (REPO / 'dm/games').glob('*/readiness.tsv'):
            s = list(status_rows(t))
            self.assertLessEqual(len(s), 1, f'{t}: more than one status row')
            for rung in s: self.assertIn(rung, STATUSES, f'{t}: status {rung!r} is not one of {", ".join(STATUSES)}')

    def test_a_rung_that_claims_it_plays_has_its_evidence(self):
        for t in (REPO / 'dm/games').glob('*/readiness.tsv'):
            rungs = list(status_rows(t))
            if not rungs or rungs[0] not in ('playable', 'wip'): continue
            tested = [l for l in t.read_text(encoding='utf-8').splitlines() if l.startswith('tested\t')]
            self.assertTrue(tested, f'{t.parent.name}: status {rungs[0]} needs a `tested` row (version, phone(s), date)')
            for row in tested:
                c = row.split('\t')
                self.assertGreaterEqual(len(c), 2, f'{t.parent.name}: tested row without a value')
                self.assertGreaterEqual(len(c[1].split()), 2, f'{t.parent.name}: tested row needs the version and the phone(s): {c[1]!r}')

    def test_no_single_game_default(self):   # the old one-game default (nxGame) is gone: build.gradle reads nxGames
        self.assertNotIn('\nnxGame=', '\n' + PROPS.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
