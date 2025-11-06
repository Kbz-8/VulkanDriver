# Stroll Vulkan ICD

<img align="right" src="https://matthew.kerwin.net.au/blog_files/kappa"/>

A driver as slow as Lance Stroll.

Here lies the source code of a rather calamitous attempt at the Vulkan specification, shaped into an Installable Client Driver for a software-based renderer, all written in Zig.

It was forged for my own learning and amusement alone. Pray, do not wield it in any earnest project, lest thy hopes and frame rates both find themselves entombed.

## Purpose

To understand Vulkan — not as a humble API mere mortals call upon, but as a labyrinthine system where one may craft a driver by hand.
It does not seek to produce a performant or production-worthy driver. \
*The gods are merciful, but not that merciful.*

## Build

If thou art truly determined:
```
zig build
```

Then ensure thy Vulkan loader is pointed toward the ICD manifest.
The precise ritual varies by system — consult the tomes of your operating system, or wander the web’s endless mausoleum of documentation.

Use at your own risk. If thy machine shudders, weeps, or attempts to flee — know that it was warned.

## License

Released unto the world as MIT for study, experimentation, and the occasional horrified whisper.
Do with it as thou wilt, but accept the consequences as thine own.
