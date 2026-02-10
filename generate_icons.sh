#!/bin/bash

# Путь к исходному изображению
SOURCE="Assets/icon.png"
DEST="Assets/AppIcon.iconset"
ICNS="Assets/AppIcon.icns"

# Проверяем наличие исходного изображения
if [ ! -f "$SOURCE" ]; then
    echo "❌ Ошибка: Файл $SOURCE не найден."
    echo "Пожалуйста, сохраните ваше изображение как '$SOURCE' (желательно размером 1024x1024)."
    exit 1
fi

echo "⚙️ Создаем набор иконок..."
mkdir -p "$DEST"

# Генерируем иконки разных размеров
sips -z 16 16     "$SOURCE" --out "$DEST/icon_16x16.png" > /dev/null
sips -z 32 32     "$SOURCE" --out "$DEST/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$SOURCE" --out "$DEST/icon_32x32.png" > /dev/null
sips -z 64 64     "$SOURCE" --out "$DEST/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$SOURCE" --out "$DEST/icon_128x128.png" > /dev/null
sips -z 256 256   "$SOURCE" --out "$DEST/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SOURCE" --out "$DEST/icon_256x256.png" > /dev/null
sips -z 512 512   "$SOURCE" --out "$DEST/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$SOURCE" --out "$DEST/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$SOURCE" --out "$DEST/icon_512x512@2x.png" > /dev/null

echo "📦 Конвертируем в .icns..."
iconutil -c icns "$DEST" -o "$ICNS"

echo "✅ Иконка создана: $ICNS"
echo "Теперь вы можете пересобрать приложение с помощью build_app.sh"
