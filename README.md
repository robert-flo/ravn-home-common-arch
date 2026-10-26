# ravn-home-common-arch

Repositorio de empaquetado Arch Linux (`PKGBUILD`) para `ravn-home-common`.

Instala todos los activos comunes de `$HOME` estrictamente bajo:
```
/usr/share/ravn/common/
├── alacritty/
├── bash/
├── bin/
│   └── ravn-home-sync
├── fcitx5/
├── fish/
├── gtk-3.0/
├── gtk-4.0/
└── mpv/
```

## Construcción Local

```bash
# Generar .SRCINFO
makepkg --printsrcinfo > .SRCINFO

# Compilar paquete
makepkg -s
```
