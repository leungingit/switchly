import { deflateSync, inflateSync } from "node:zlib";

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const MAX_DIMENSION = 8192;
const MAX_PIXELS = 32 * 1024 * 1024;

export class PngError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/**
 * 解码 8 位、非隔行的 RGB / RGBA PNG 为 RGBA。其他格式明确拒绝，
 * 不尝试"尽量解码"，避免基线比较在不可信输入上给出似是而非的结果。
 */
export function decodePng(buffer) {
  if (buffer.length < 33 || !buffer.subarray(0, 8).equals(SIGNATURE)) throw new PngError("invalid-png");
  let offset = 8;
  let header = null;
  const data = [];
  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("latin1", offset + 4, offset + 8);
    const end = offset + 12 + length;
    if (end > buffer.length) throw new PngError("invalid-png");
    const body = buffer.subarray(offset + 8, offset + 8 + length);
    if (buffer.readUInt32BE(offset + 8 + length) !== crc32(buffer.subarray(offset + 4, offset + 8 + length))) {
      throw new PngError("invalid-png");
    }
    if (type === "IHDR") {
      if (length !== 13) throw new PngError("invalid-png");
      header = {
        width: body.readUInt32BE(0),
        height: body.readUInt32BE(4),
        depth: body[8],
        colorType: body[9],
        interlace: body[12],
      };
    } else if (type === "IDAT") {
      data.push(body);
    } else if (type === "IEND") {
      break;
    }
    offset = end;
  }
  if (!header || data.length === 0) throw new PngError("invalid-png");
  const { width, height, depth, colorType, interlace } = header;
  if (depth !== 8 || interlace !== 0 || (colorType !== 2 && colorType !== 6)) throw new PngError("unsupported-png");
  if (width === 0 || height === 0 || width > MAX_DIMENSION || height > MAX_DIMENSION || width * height > MAX_PIXELS) {
    throw new PngError("png-too-large");
  }
  const channels = colorType === 6 ? 4 : 3;
  const stride = width * channels;
  let raw;
  try {
    raw = inflateSync(Buffer.concat(data), { maxOutputLength: (stride + 1) * height });
  } catch {
    throw new PngError("invalid-png");
  }
  if (raw.length !== (stride + 1) * height) throw new PngError("invalid-png");

  const rgba = new Uint8Array(width * height * 4);
  let previous = new Uint8Array(stride);
  for (let y = 0; y < height; y += 1) {
    const filter = raw[y * (stride + 1)];
    const line = new Uint8Array(raw.buffer, raw.byteOffset + y * (stride + 1) + 1, stride).slice();
    for (let x = 0; x < stride; x += 1) {
      const left = x >= channels ? line[x - channels] : 0;
      const up = previous[x];
      const upLeft = x >= channels ? previous[x - channels] : 0;
      let predictor;
      switch (filter) {
        case 0: predictor = 0; break;
        case 1: predictor = left; break;
        case 2: predictor = up; break;
        case 3: predictor = (left + up) >> 1; break;
        case 4: {
          const p = left + up - upLeft;
          const pa = Math.abs(p - left);
          const pb = Math.abs(p - up);
          const pc = Math.abs(p - upLeft);
          predictor = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
          break;
        }
        default: throw new PngError("invalid-png");
      }
      line[x] = (line[x] + predictor) & 0xff;
    }
    for (let x = 0; x < width; x += 1) {
      const target = (y * width + x) * 4;
      rgba[target] = line[x * channels];
      rgba[target + 1] = line[x * channels + 1];
      rgba[target + 2] = line[x * channels + 2];
      rgba[target + 3] = channels === 4 ? line[x * channels + 3] : 255;
    }
    previous = line;
  }
  return { width, height, rgba };
}

function chunk(type, body) {
  const out = Buffer.alloc(12 + body.length);
  out.writeUInt32BE(body.length, 0);
  out.write(type, 4, "latin1");
  body.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
  return out;
}

export function encodePng({ width, height, rgba }) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  return Buffer.concat([SIGNATURE, chunk("IHDR", header), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}
