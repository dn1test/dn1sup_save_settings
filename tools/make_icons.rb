# frozen_string_literal: true
# =============================================================================
# tools/make_icons.rb — генерация растровых PNG иконок тулбара:
#   • векторный SVG: icons/ss.svg (для современных версий SketchUp);
#   • растровые PNG: icons/ss_16.png, ss_24.png (fallback для старых версий,
#     см. setup_toolbar в main.rb).
#   (рендеринг чистым Ruby с 4x суперсэмплингом и антиалиасингом).
#
# Дизайн (НЕ менять): синяя дискета (градиент #36abf7→#006fb8), верхняя белая
# шторка + синяя прорезь, нижнее белое окно + две серые строки, зелёный
# круг-бейдж (#22c55e→#16a34a) с тремя белыми полосками (zip-архив).
# =============================================================================

require 'zlib'
require 'fileutils'

SVG_CONTENT = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
    <defs>
      <linearGradient id="ssBody" x1="0%" y1="0%" x2="0%" y2="100%">
        <stop offset="0%" stop-color="#36abf7"/>
        <stop offset="100%" stop-color="#006fb8"/>
      </linearGradient>
      <linearGradient id="ssBadge" x1="0%" y1="0%" x2="0%" y2="100%">
        <stop offset="0%" stop-color="#22c55e"/>
        <stop offset="100%" stop-color="#16a34a"/>
      </linearGradient>
    </defs>
    <!-- Корпус дискеты (сохранение) -->
    <path d="M4 3.5A1.5 1.5 0 0 1 5.5 2h11.6a2 2 0 0 1 1.4.6l2.9 2.9a2 2 0 0 1 .6 1.4V20a2 2 0 0 1-2 2h-14A1.5 1.5 0 0 1 4 20.5v-17z" fill="url(#ssBody)"/>
    <!-- Верхняя шторка с прорезью -->
    <rect x="7" y="2" width="10" height="6.5" rx="1" fill="#ffffff" opacity="0.95"/>
    <rect x="11.2" y="3.2" width="4" height="4.2" rx="0.6" fill="#006fb8" opacity="0.85"/>
    <!-- Нижнее окно данных -->
    <rect x="7" y="12" width="10" height="10" rx="1" fill="#ffffff" opacity="0.92"/>
    <line x1="9" y1="15" x2="15" y2="15" stroke="#94a3b8" stroke-width="1.1" stroke-linecap="round"/>
    <line x1="9" y1="17.5" x2="13" y2="17.5" stroke="#cbd5e1" stroke-width="1.1" stroke-linecap="round"/>
    <!-- Бейдж архива (zip) -->
    <circle cx="17.5" cy="17.5" r="4.5" fill="url(#ssBadge)"/>
    <rect x="16.1" y="14.4" width="2.8" height="0.9" rx="0.45" fill="#ffffff"/>
    <rect x="16.1" y="15.8" width="2.8" height="0.9" rx="0.45" fill="#ffffff"/>
    <rect x="16.1" y="17.2" width="2.8" height="0.9" rx="0.45" fill="#ffffff"/>
  </svg>
SVG

# -- PNG сборщик -------------------------------------------------------------

def png_chunk(type, data)
  [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
end

def write_png(path, pixels, width, height)
  raw = pixels.map { |row| "\x00" + row.map { |px| px.pack('C4') }.join }.join
  png = "\x89PNG\r\n\x1a\n".b +
        png_chunk('IHDR', [width, height, 8, 6, 0, 0, 0].pack('N5')) +
        png_chunk('IDAT', Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)) +
        png_chunk('IEND', '')
  File.binwrite(path, png)
  puts "  ✓ #{File.basename(path)} (#{width}x#{height})"
end

# -- Канва с альфа-блендингом -------------------------------------------------

class ImageBuffer
  attr_reader :w, :h, :pixels

  def initialize(w, h)
    @w = w
    @h = h
    @pixels = Array.new(h) { Array.new(w) { [0, 0, 0, 0] } }
  end

  def blend_pixel(x, y, r, g, b, a)
    return if x < 0 || x >= @w || y < 0 || y >= @h || a <= 0

    cur = @pixels[y][x]
    sa = a / 255.0
    da = cur[3] / 255.0
    out_a = sa + da * (1.0 - sa)
    return if out_a.zero?

    out_r = ((r * sa + cur[0] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    out_g = ((g * sa + cur[1] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    out_b = ((b * sa + cur[2] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    @pixels[y][x] = [out_r, out_g, out_b, (out_a * 255).round.clamp(0, 255)]
  end

  # Сглаженный спуск (4x бокс-фильтр) в результирующий буфер
  def downsample(scale = 4)
    target_w = @w / scale
    target_h = @h / scale
    out = Array.new(target_h) { Array.new(target_w) { [0, 0, 0, 0] } }

    target_h.times do |ty|
      target_w.times do |tx|
        sum_r = 0.0
        sum_g = 0.0
        sum_b = 0.0
        sum_a = 0.0

        scale.times do |sy|
          scale.times do |sx|
            px = @pixels[ty * scale + sy][tx * scale + sx]
            a = px[3] / 255.0
            sum_r += px[0] * a
            sum_g += px[1] * a
            sum_b += px[2] * a
            sum_a += a
          end
        end

        count = (scale * scale).to_f
        avg_a = sum_a / count
        if avg_a > 0.001
          avg_r = (sum_r / sum_a).round.clamp(0, 255)
          avg_g = (sum_g / sum_a).round.clamp(0, 255)
          avg_b = (sum_b / sum_a).round.clamp(0, 255)
          out[ty][tx] = [avg_r, avg_g, avg_b, (avg_a * 255).round.clamp(0, 255)]
        end
      end
    end
    out
  end
end

# -- Геометрия ----------------------------------------------------------------

# Точка (nx, ny) внутри скруглённого прямоугольника [x0,y0,x1,y1], радиус r.
def rounded_rect?(nx, ny, x0, y0, x1, y1, r)
  return false if nx < x0 || nx > x1 || ny < y0 || ny > y1

  cx = nx < x0 + r ? x0 + r : (nx > x1 - r ? x1 - r : nx)
  cy = ny < y0 + r ? y0 + r : (ny > y1 - r ? y1 - r : ny)
  (nx - cx)**2 + (ny - cy)**2 <= r * r
end

def lerp_channel(a, b, t)
  (a * (1 - t) + b * t).round
end

# -- Рендеринг иконки высокого разрешения (на сетке 24 x 24) ------------------

def render_icon(target_size)
  scale = 4
  hires = target_size * scale
  buf = ImageBuffer.new(hires, hires)
  s = hires / 24.0

  hires.times do |y|
    ny = (y + 0.5) / s
    hires.times do |x|
      nx = (x + 0.5) / s

      # 1. Корпус дискеты: x 4..22, y 2..22, скругление 1.5, срез правого
      #    верхнего угла по линии через (17.1,2)-(22,6.9): вне, если nx-ny > 15.1.
      in_body = nx >= 4.0 && nx <= 22.0 && ny >= 2.0 && ny <= 22.0
      in_body = false if in_body && nx > 17.1 && ny < 6.9 && (nx - ny) > 15.1
      if in_body
        rad = 1.5
        corners_ok = rounded_rect?(nx, ny, 4.0, 2.0, 22.0, 22.0, rad)
        # Срезанный угол не скругляем — линия среза уже учтена выше.
        corners_ok = true if nx > 22.0 - 5.0 && ny < 2.0 + 5.0
        if corners_ok
          t = ((ny - 2.0) / 20.0).clamp(0.0, 1.0)
          # Градиент #36abf7 -> #006fb8
          r = lerp_channel(0x36, 0x00, t)
          g = lerp_channel(0xab, 0x6f, t)
          b = lerp_channel(0xf7, 0xb8, t)
          buf.blend_pixel(x, y, r, g, b, 255)
        end
      end

      # 2. Верхняя белая шторка: x 7..17, y 2..8.5, rx 1, opacity 0.95.
      if rounded_rect?(nx, ny, 7.0, 2.0, 17.0, 8.5, 1.0)
        # Синяя прорезь: x 11.2..15.2, y 3.2..7.4, rx 0.6, opacity 0.85.
        if rounded_rect?(nx, ny, 11.2, 3.2, 15.2, 7.4, 0.6)
          buf.blend_pixel(x, y, 0x00, 0x6f, 0xb8, (0.85 * 255).round)
        else
          buf.blend_pixel(x, y, 255, 255, 255, (0.95 * 255).round)
        end
      end

      # 3. Нижнее белое окно: x 7..17, y 12..22, rx 1, opacity 0.92.
      if rounded_rect?(nx, ny, 7.0, 12.0, 17.0, 22.0, 1.0)
        buf.blend_pixel(x, y, 255, 255, 255, (0.92 * 255).round)
        # Две серые строки (round caps учтены расширением сегмента на w/2).
        if (ny - 15.0).abs <= 0.55 && nx >= 9.0 - 0.55 && nx <= 15.0 + 0.55
          buf.blend_pixel(x, y, 0x94, 0xa3, 0xb8, 255)
        elsif (ny - 17.5).abs <= 0.55 && nx >= 9.0 - 0.55 && nx <= 13.0 + 0.55
          buf.blend_pixel(x, y, 0xcb, 0xd5, 0xe1, 255)
        end
      end

      # 4. Зелёный бейдж архива: центр (17.5,17.5), r=4.5,
      #    градиент #22c55e -> #16a34a.
      dx = nx - 17.5
      dy = ny - 17.5
      if dx * dx + dy * dy <= 4.5 * 4.5
        t = ((ny - 13.0) / 9.0).clamp(0.0, 1.0)
        r = lerp_channel(0x22, 0x16, t)
        g = lerp_channel(0xc5, 0xa3, t)
        b = lerp_channel(0x5e, 0x4a, t)
        buf.blend_pixel(x, y, r, g, b, 255)
        # Три белые полоски zip: x 16.1..18.9, h 0.9, rx 0.45.
        if rounded_rect?(nx, ny, 16.1, 14.4, 18.9, 15.3, 0.45) ||
           rounded_rect?(nx, ny, 16.1, 15.8, 18.9, 16.7, 0.45) ||
           rounded_rect?(nx, ny, 16.1, 17.2, 18.9, 18.1, 0.45)
          buf.blend_pixel(x, y, 255, 255, 255, 255)
        end
      end
    end
  end

  buf.downsample(scale)
end

# -- Генерация файлов в папке icons ------------------------------------------

out = File.join(__dir__, '..', 'dn1sup_save_settings', 'dn1sup_save_settings', 'icons')
FileUtils.mkdir_p(out)
puts "Генерация иконок в #{out}:"

# 1. Проверка: встроенный SVG совпадает с icons/ss.svg (дизайн — эталон).
svg_path = File.join(out, 'ss.svg')
if File.file?(svg_path)
  disk = File.read(svg_path, encoding: 'UTF-8').gsub(/\r\n?/, "\n").strip
  embedded = SVG_CONTENT.gsub(/\r\n?/, "\n").strip
  if disk == embedded
    puts '  ✓ ss.svg совпадает со встроенным (дизайн не менялся)'
  else
    warn '  ! ВНИМАНИЕ: icons/ss.svg отличается от встроенного SVG — PNG отрисованы по встроенному'
  end
else
  File.write(svg_path, SVG_CONTENT, encoding: 'UTF-8')
  puts '  ✓ ss.svg (Vector, восстановлен из встроенного)'
end

# 2. PNG размеры (fallback для SketchUp < 16 в setup_toolbar).
[16, 24].each do |size|
  px = render_icon(size)
  write_png(File.join(out, "ss_#{size}.png"), px, size, size)
end

puts "\nГотово! Все иконки успешно созданы."
