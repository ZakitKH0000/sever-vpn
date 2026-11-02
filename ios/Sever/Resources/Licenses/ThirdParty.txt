# Сторонние компоненты

## Xray

- [Xray-core](https://github.com/XTLS/Xray-core), Mozilla Public License 2.0.
- [XTLS/libXray](https://github.com/XTLS/libXray), MIT.
- Используется официальный Apple CGO релиз `v26.10.31`.
- Архив: `libxray-apple-cgo.zip`.
- SHA-256: `2666babc1a91d8570a49bc817487338e7a71f17618e02a601e861928d254b95a`.
- Бинарный артефакт скачивается при подготовке зависимостей, не публикуется
  в исходном репозитории. Исходники, уведомления об авторских правах и лицензии
  доступны в закреплённом upstream-релизе и репозиториях его компонентов.

## OpenVPN

- [Windscribe/iOSOpenVPNAdapter](https://github.com/Windscribe/iOSOpenVPNAdapter).
- Зафиксирован коммит `5dacd45e47ca9658d11861f760d5d20677c547b6`, тег `3.11.7`.
- OpenVPN3: AGPLv3; mbedTLS: Apache 2.0; ASIO: Boost Software License;
  LZ4: BSD 2-Clause. Лицензии и исходники компонентов находятся в upstream.
- Swift Package Manager собирает адаптер из закреплённых исходников.
- Это не официальное приложение Windscribe и не доступ к серверам Windscribe.

## Бесплатный каталог

[VPN Gate Academic Experiment Project](https://www.vpngate.net/en/) — внешний
публичный каталог добровольческих серверов. На сайте явно предусмотрен
CSV-интерфейс для собственных клиентов. Это не собственность «Севера» и не
источник гарантированно доступных узлов. Действуют условия VPN Gate и
владельцев конкретных серверов.

## Средства разработки

XcodeGen, Node.js, Python, Tree-sitter, PyYAML и Pillow используются для разработки,
проверки или сборки. Python-пакеты в `.tools` в приложение не включаются.
Геометрический знак компаса нарисован скриптом этого проекта.
