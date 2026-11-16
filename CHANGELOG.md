# Changelog
All notable changes to this project will be documented in this file. See [conventional commits](https://www.conventionalcommits.org/) for commit guidelines.

- - -
## [0.1.0](https://github.com/sravioli/harbor.wz/compare/2b3c21bd0688e77180ebb5abc1154fcd9bb2f1e3..0.1.0) - 2026-11-16
#### Features
- (**api**) add has_session lookup - ([93e7e6b](https://github.com/sravioli/harbor.wz/commit/93e7e6b51dba28f2937d6e364d20b43f833f2530)) - sravioli
- (**core**) add config state and history - ([e233aaa](https://github.com/sravioli/harbor.wz/commit/e233aaa9e527358182ae38e1f518e926f2392ac6)) - sravioli
- (**events**) add switching and picker lifecycle events - ([56eeac4](https://github.com/sravioli/harbor.wz/commit/56eeac4f7e5c3b14a81521d3e49ad511c3fcd022)) - sravioli
- (**harbor**) place picker hints in status - ([0c0ea4c](https://github.com/sravioli/harbor.wz/commit/0c0ea4cd0b9c0b44f254ed721a61ebc50aa0b73c)) - sravioli
- (**layout**) add workspace layout rules - ([8fcc8d2](https://github.com/sravioli/harbor.wz/commit/8fcc8d2a1f66d5e2aa67757b40e9e64cca8462a2)) - sravioli
- (**picker**) show window, tab and pane counts for live workspaces - ([a78c798](https://github.com/sravioli/harbor.wz/commit/a78c7986ac776b60eca8bf75b12e0b146ae3d66b)) - sravioli
- (**picker**) clearer delete confirm and notice - ([0f6aabc](https://github.com/sravioli/harbor.wz/commit/0f6aabc4d0d7c283d9e32cc65646a47d9acf1839)) - sravioli
- (**picker**) expose workspace actions and API - ([b08de71](https://github.com/sravioli/harbor.wz/commit/b08de71c5e57eee1f76f05427b11246143c3d73d)) - sravioli
- (**session**) warn on restore when a pane's git branch changed - ([aaffccf](https://github.com/sravioli/harbor.wz/commit/aaffccf7042d3e5d76afd91875704186e36d603a)) - sravioli
- (**session**) save and load tab and window snapshots - ([a492e34](https://github.com/sravioli/harbor.wz/commit/a492e3405d0696b1975f776970655d4e8b72efcd)) - sravioli
- (**session**) add persistence and autosave - ([ea838a2](https://github.com/sravioli/harbor.wz/commit/ea838a215c9006a0fd4f52fc39d99aecef41485e)) - sravioli
- (**sources**) add workspace discovery - ([1b0bfe7](https://github.com/sravioli/harbor.wz/commit/1b0bfe7dc1c07e3888bd0c25da0357b1f331f0cc)) - sravioli
- (**workspace**) fork the active workspace - ([1741912](https://github.com/sravioli/harbor.wz/commit/17419127238869ce251ca480fa85c7bcd91bd8df)) - sravioli
- (**workspace**) cycle through workspaces alphabetically - ([81a0b39](https://github.com/sravioli/harbor.wz/commit/81a0b39da4b24788fe3391253ce5886774eb61ca)) - sravioli
- harden close, quit, restore and save age - ([ab9d686](https://github.com/sravioli/harbor.wz/commit/ab9d6865b0546fdc460ad366fcf5ae71994e07ec)) - sravioli
#### Bug Fixes
- (**auto**) guard autosave generations - ([c413713](https://github.com/sravioli/harbor.wz/commit/c413713cfd6e096732db21c2b74418a0f0015c2c)) - sravioli
- (**capture**) refuse incomplete captures - ([8f9b3fb](https://github.com/sravioli/harbor.wz/commit/8f9b3fb830c9763293ec99c46a67cbbc4a96ccce)) - sravioli
- (**ci**) clone sibling plugins for specs - ([6387f96](https://github.com/sravioli/harbor.wz/commit/6387f963da1f475a55d0ce93821fef0124ab9f3f)) - sravioli
- (**history**) copy GLOBAL lists before ipairs - ([546128b](https://github.com/sravioli/harbor.wz/commit/546128bea4a722197f648834f0fd29effbb30228)) - sravioli
- (**restore**) report partial restores - ([edaace5](https://github.com/sravioli/harbor.wz/commit/edaace502e1b55a7a4efde522cc47ad1befeb428)) - sravioli
- (**session**) harden session files and skip git outside repos - ([73578ca](https://github.com/sravioli/harbor.wz/commit/73578cad429c4b3718d646f04df568cd5c9cfb27)) - sravioli
- (**session**) keep snapshot loads from protecting the live workspace - ([b91101c](https://github.com/sravioli/harbor.wz/commit/b91101ceb69cab4e84bbbe06185dd05710f96505)) - sravioli
- (**store**) restore .json and truncated names - ([8b77db4](https://github.com/sravioli/harbor.wz/commit/8b77db4241161266ba3d7580ed94139c751a52c0)) - sravioli
- (**store**) validate session trees and backups - ([7ce3c5e](https://github.com/sravioli/harbor.wz/commit/7ce3c5e768bc9f69c49fe76b4d70049fc684e093)) - sravioli
- (**workspace**) harden close and rename - ([501857d](https://github.com/sravioli/harbor.wz/commit/501857d915e366646a4c81ab1c9a72d94fe9b508)) - sravioli
#### Performance Improvements
- (**bootstrap**) keep plugin list across reloads - ([6aad653](https://github.com/sravioli/harbor.wz/commit/6aad6530b4d9aee3c6222e01d2c08a3c1fc4c6f6)) - sravioli
#### Documentation
- (**readme**) document session file hardening and fix stale dev notes - ([20483dc](https://github.com/sravioli/harbor.wz/commit/20483dc09e8fb56b5b798bd33943c9dfe959fdca)) - sravioli
- (**readme**) note snapshots must be in a custom sources.order - ([7d5ea11](https://github.com/sravioli/harbor.wz/commit/7d5ea11798a589ea95045b26a54a8f985418e8af)) - sravioli
- (**readme**) add coverage badge - ([0f584cd](https://github.com/sravioli/harbor.wz/commit/0f584cd56e193f15b77217968f5190939f33e1c6)) - sravioli
- (**readme**) document remote install and add CI badges - ([421a892](https://github.com/sravioli/harbor.wz/commit/421a892277782b48b1f4a7e89594bfa60c6ee640)) - sravioli
- (**readme**) unify badge style and add release badge - ([f9e1aff](https://github.com/sravioli/harbor.wz/commit/f9e1aff96baf1f55e533eddd8193b446f868b6d3)) - sravioli
- (**readme**) align checks section - ([7eede49](https://github.com/sravioli/harbor.wz/commit/7eede498ad27bf7c5a2c4d71193fba142c767c82)) - sravioli
- (**readme**) update plugin READMEs - ([5a72240](https://github.com/sravioli/harbor.wz/commit/5a72240d75c3ae93d8b9265b7a9a3bcd0e282c54)) - sravioli
- document working-tree local checkout setup - ([6f85363](https://github.com/sravioli/harbor.wz/commit/6f853634c0778b4606125dea0d6c42e460057494)) - sravioli
- document close, quit and rollback changes - ([cd8490f](https://github.com/sravioli/harbor.wz/commit/cd8490fe7b65587d061ec0562087c7acc0293346)) - sravioli
- document session recovery limits - ([51707d0](https://github.com/sravioli/harbor.wz/commit/51707d04a64372a2854829c26e670c16a9ecc3f5)) - sravioli
- document Harbor usage and licensing - ([2c46042](https://github.com/sravioli/harbor.wz/commit/2c460429784b8af1eec6b62a72ad0304d05c3e97)) - sravioli
#### Tests
- (**history**) cover empty list stored as object - ([f69a652](https://github.com/sravioli/harbor.wz/commit/f69a6522459afeb42ad76b9a1d7a7690d3a0fadf)) - sravioli
- (**mocks**) truncate by codepoint - ([6773bff](https://github.com/sravioli/harbor.wz/commit/6773bff707552473aa6aa52daf58cad9d514ddcc)) - sravioli
- (**picker**) cover delete confirm and notice - ([06ab399](https://github.com/sravioli/harbor.wz/commit/06ab3995513166cb63b8f0629a0f14cb549a3d13)) - sravioli
- (**store**) cover .json and truncated names - ([ea96f03](https://github.com/sravioli/harbor.wz/commit/ea96f0303790c8017f51c59960f44990a60c42eb)) - sravioli
- cover close, quit, rollback and save age - ([9640a46](https://github.com/sravioli/harbor.wz/commit/9640a4691ace7f0e99efba025a93da549124d2ee)) - sravioli
- add session round-trip coverage - ([4c3d067](https://github.com/sravioli/harbor.wz/commit/4c3d067b6e1a207ee5c934d208db81f23eaebc3c)) - sravioli
#### Build system
- add plugin tooling and test harness - ([2b3c21b](https://github.com/sravioli/harbor.wz/commit/2b3c21bd0688e77180ebb5abc1154fcd9bb2f1e3)) - sravioli
#### Refactoring
- (**session**) extract window and tab helpers from capture and restore - ([82a2a39](https://github.com/sravioli/harbor.wz/commit/82a2a3908ecea7dd96d977552f9f7040254ed007)) - sravioli

- - -

