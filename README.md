# Teleprompter (iPhone, iOS 17+)

Tekst przewija się w oknie **Obraz w Obrazie (PiP)**, które iOS trzyma nad każdą inną aplikacją:
aparatem, Instagramem, TikTokiem, Zoomem. Okno można przesuwać, powiększać (szczypnięcie)
i pauzować przyciskiem ▶︎/⏸ w samym oknie.

## Użycie
1. Wklej tekst, ustaw prędkość i czcionkę.
2. Stuknij **Pływające okno** (albo po prostu wyjdź z aplikacji gestem do ekranu głównego).
3. Otwórz aparat i nagrywaj. Start/pauza: przycisk w oknie PiP.

## Instalacja z Windowsa (bez Maca)
1. Wrzuć ten folder do nowego repozytorium na GitHubie. Akcja `build-ipa` zbuduje `Teleprompter.ipa`
   (zakładka **Actions** → ostatni build → **Artifacts**).
2. Zainstaluj na iPhonie przez [Sideloadly](https://sideloadly.io) (Windows) i swoje Apple ID.
3. Na iPhonie: Ustawienia → Ogólne → VPN i urządzenia → zaufaj certyfikatowi;
   Ustawienia → Prywatność i ochrona → **Tryb dewelopera** → włącz.

Darmowe Apple ID: aplikacja działa 7 dni, potem ponów krok 2. Płatne konto deweloperskie (99 USD/rok): rok
i możliwość TestFlight.

## Z Maca
```
brew install xcodegen && xcodegen && open Teleprompter.xcodeproj
```
Wybierz swój zespół w Signing & Capabilities i uruchom na telefonie.
