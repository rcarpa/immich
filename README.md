A personal fork of the [Immich](https://github.com/immich-app/immich) iOS client that
stores photos on the phone so they open without a network. I made this for myself.

Pick the whole library or specific albums, and a quality: previews, full size, or full
size with videos. The client downloads those files and keeps them until you remove
them. When the server is unreachable or the session has expired, it keeps working with
what is stored instead of sending you to the login screen.

It is entirely vibe-coded: an LLM wrote every line of it. Upstreaming any of this is
therefore unlikely — I have no experience with iOS development or the languages
involved, so I could not do that work myself.

Only the iOS client is changed. The server, web and CLI in this repository are
upstream's code.

## Trying it

TestFlight build: **[testflight.apple.com/join/nnYj2ufn](https://testflight.apple.com/join/nnYj2ufn)**.

AltStore users with a paid Apple Developer account (free tier will not work) can add 
this source instead: **`https://rcarpa.fr/mirrich/source.json`**. 

I run this on my phone and change it when I need to (most probably, not very frequently). 

Building it yourself: [mobile/BUILDING.md](mobile/BUILDING.md). What it does and why:
[mobile/FORK.md](mobile/FORK.md).

## Licence

AGPL-3.0, inherited from Immich — see [LICENSE](LICENSE). Not affiliated with or
endorsed by the Immich project. It uses a different name and icon to respect the
terms of the licence and to be able to have it published in TestFlight.
