(function () {
  "use strict";

  function render(value, image) {
    const svg = createQrSvg(value);
    image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  }

  function createQrSvg(value) {
    const matrix = createQrMatrix(value);
    const quiet = 4;
    const imageSize = matrix.length + quiet * 2;
    let path = "";
    matrix.forEach((row, rowIndex) => {
      row.forEach((dark, columnIndex) => {
        if (dark) {
          path += `M${columnIndex + quiet},${rowIndex + quiet}h1v1h-1z`;
        }
      });
    });
    return [
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${imageSize} ${imageSize}" shape-rendering="crispEdges">`,
      `<rect width="${imageSize}" height="${imageSize}" fill="#fff6e8"/>`,
      `<path fill="#100f0e" d="${path}"/>`,
      "</svg>"
    ].join("");
  }

  function createQrMatrix(value) {
    const version = 10;
    const size = 17 + version * 4;
    const dataBlockLengths = [68, 68, 69, 69];
    const eccLength = 18;
    const dataCodewords = 274;
    const maxByteLength = 271;
    const bytes = [...new TextEncoder().encode(value)];
    if (bytes.length > maxByteLength) {
      throw new Error("WireGuard config is too long for this QR code");
    }

    const bitBuffer = [];
    appendBits(bitBuffer, 0b0100, 4);
    appendBits(bitBuffer, bytes.length, 16);
    bytes.forEach((byte) => appendBits(bitBuffer, byte, 8));
    const maxBits = dataCodewords * 8;
    appendBits(bitBuffer, 0, Math.min(4, maxBits - bitBuffer.length));
    while (bitBuffer.length % 8 !== 0) {
      bitBuffer.push(0);
    }

    const codewords = [];
    for (let index = 0; index < bitBuffer.length; index += 8) {
      codewords.push(bitsToByte(bitBuffer.slice(index, index + 8)));
    }
    for (let pad = 0xec; codewords.length < dataCodewords; pad = pad === 0xec ? 0x11 : 0xec) {
      codewords.push(pad);
    }

    const blocks = [];
    let cursor = 0;
    dataBlockLengths.forEach((length) => {
      const data = codewords.slice(cursor, cursor + length);
      blocks.push({ data, ecc: reedSolomonRemainder(data, eccLength) });
      cursor += length;
    });

    const finalCodewords = [];
    for (let index = 0; index < Math.max(...dataBlockLengths); index += 1) {
      blocks.forEach((block) => {
        if (index < block.data.length) {
          finalCodewords.push(block.data[index]);
        }
      });
    }
    for (let index = 0; index < eccLength; index += 1) {
      blocks.forEach((block) => finalCodewords.push(block.ecc[index]));
    }

    const matrix = Array.from({ length: size }, () => Array(size).fill(false));
    const reserved = Array.from({ length: size }, () => Array(size).fill(false));
    const setFunction = (row, column, dark) => {
      if (row < 0 || row >= size || column < 0 || column >= size) {
        return;
      }
      matrix[row][column] = dark;
      reserved[row][column] = true;
    };

    drawFinder(matrix, reserved, 0, 0);
    drawFinder(matrix, reserved, 0, size - 7);
    drawFinder(matrix, reserved, size - 7, 0);
    for (let index = 8; index < size - 8; index += 1) {
      const dark = index % 2 === 0;
      setFunction(6, index, dark);
      setFunction(index, 6, dark);
    }
    [6, 28, 50].forEach((row) => {
      [6, 28, 50].forEach((column) => {
        const overlapsFinder =
          (row < 9 && column < 9) ||
          (row < 9 && column > size - 10) ||
          (row > size - 10 && column < 9);
        if (!overlapsFinder) {
          drawAlignment(matrix, reserved, row, column);
        }
      });
    });
    reserveFormatAndVersion(setFunction, size, version);
    placeData(matrix, reserved, finalCodewords);
    drawFormatBits(setFunction, size, 0);
    drawVersionBits(setFunction, size, version);
    return matrix;
  }

  function appendBits(buffer, value, length) {
    for (let bit = length - 1; bit >= 0; bit -= 1) {
      buffer.push((value >>> bit) & 1);
    }
  }

  function bitsToByte(bits) {
    return bits.reduce((byte, bit) => (byte << 1) | bit, 0);
  }

  function drawFinder(matrix, reserved, row, column) {
    const setFunction = (targetRow, targetColumn, dark) => {
      if (targetRow < 0 || targetRow >= matrix.length || targetColumn < 0 || targetColumn >= matrix.length) {
        return;
      }
      matrix[targetRow][targetColumn] = dark;
      reserved[targetRow][targetColumn] = true;
    };
    for (let offsetRow = -1; offsetRow <= 7; offsetRow += 1) {
      for (let offsetColumn = -1; offsetColumn <= 7; offsetColumn += 1) {
        const inPattern = offsetRow >= 0 && offsetRow <= 6 && offsetColumn >= 0 && offsetColumn <= 6;
        const dark =
          inPattern &&
          (offsetRow === 0 ||
            offsetRow === 6 ||
            offsetColumn === 0 ||
            offsetColumn === 6 ||
            (offsetRow >= 2 && offsetRow <= 4 && offsetColumn >= 2 && offsetColumn <= 4));
        setFunction(row + offsetRow, column + offsetColumn, dark);
      }
    }
  }

  function drawAlignment(matrix, reserved, row, column) {
    for (let offsetRow = -2; offsetRow <= 2; offsetRow += 1) {
      for (let offsetColumn = -2; offsetColumn <= 2; offsetColumn += 1) {
        const distance = Math.max(Math.abs(offsetRow), Math.abs(offsetColumn));
        const targetRow = row + offsetRow;
        const targetColumn = column + offsetColumn;
        matrix[targetRow][targetColumn] = distance !== 1;
        reserved[targetRow][targetColumn] = true;
      }
    }
  }

  function reserveFormatAndVersion(setFunction, size, version) {
    for (let index = 0; index < 9; index += 1) {
      if (index !== 6) {
        setFunction(8, index, false);
        setFunction(index, 8, false);
      }
    }
    for (let index = 0; index < 8; index += 1) {
      setFunction(8, size - 1 - index, false);
      setFunction(size - 1 - index, 8, false);
    }
    setFunction(size - 8, 8, true);
    if (version >= 7) {
      for (let row = 0; row < 6; row += 1) {
        for (let column = 0; column < 3; column += 1) {
          setFunction(row, size - 11 + column, false);
          setFunction(size - 11 + column, row, false);
        }
      }
    }
  }

  function placeData(matrix, reserved, codewords) {
    const bits = [];
    codewords.forEach((codeword) => appendBits(bits, codeword, 8));
    let bitIndex = 0;
    let upward = true;
    for (let right = matrix.length - 1; right >= 1; right -= 2) {
      if (right === 6) {
        right -= 1;
      }
      for (let vertical = 0; vertical < matrix.length; vertical += 1) {
        const row = upward ? matrix.length - 1 - vertical : vertical;
        for (let offset = 0; offset < 2; offset += 1) {
          const column = right - offset;
          if (reserved[row][column]) {
            continue;
          }
          const dataBit = bitIndex < bits.length ? bits[bitIndex] === 1 : false;
          const mask = (row + column) % 2 === 0;
          matrix[row][column] = dataBit !== mask;
          bitIndex += 1;
        }
      }
      upward = !upward;
    }
  }

  function drawFormatBits(setFunction, size, mask) {
    const data = (1 << 3) | mask;
    let remainder = data << 10;
    for (let bit = 14; bit >= 10; bit -= 1) {
      if (((remainder >>> bit) & 1) !== 0) {
        remainder ^= 0x537 << (bit - 10);
      }
    }
    const bits = ((data << 10) | remainder) ^ 0x5412;
    const getBit = (index) => ((bits >>> index) & 1) !== 0;
    for (let index = 0; index <= 5; index += 1) {
      setFunction(index, 8, getBit(index));
    }
    setFunction(7, 8, getBit(6));
    setFunction(8, 8, getBit(7));
    setFunction(8, 7, getBit(8));
    for (let index = 9; index < 15; index += 1) {
      setFunction(8, 14 - index, getBit(index));
    }
    for (let index = 0; index < 8; index += 1) {
      setFunction(8, size - 1 - index, getBit(index));
    }
    for (let index = 8; index < 15; index += 1) {
      setFunction(size - 15 + index, 8, getBit(index));
    }
    setFunction(size - 8, 8, true);
  }

  function drawVersionBits(setFunction, size, version) {
    let remainder = version;
    for (let index = 0; index < 12; index += 1) {
      remainder = (remainder << 1) ^ (((remainder >>> 11) & 1) * 0x1f25);
    }
    const bits = (version << 12) | remainder;
    const getBit = (index) => ((bits >>> index) & 1) !== 0;
    for (let index = 0; index < 18; index += 1) {
      const a = size - 11 + (index % 3);
      const b = Math.floor(index / 3);
      const bit = getBit(index);
      setFunction(b, a, bit);
      setFunction(a, b, bit);
    }
  }

  const qrExp = [];
  const qrLog = [];
  for (let value = 1, exponent = 0; exponent < 255; exponent += 1) {
    qrExp[exponent] = value;
    qrLog[value] = exponent;
    value <<= 1;
    if (value & 0x100) {
      value ^= 0x11d;
    }
  }
  for (let exponent = 255; exponent < 512; exponent += 1) {
    qrExp[exponent] = qrExp[exponent - 255];
  }

  function gfMultiply(left, right) {
    if (left === 0 || right === 0) {
      return 0;
    }
    return qrExp[qrLog[left] + qrLog[right]];
  }

  function reedSolomonRemainder(data, degree) {
    const generator = reedSolomonGenerator(degree);
    const result = [...data, ...Array(degree).fill(0)];
    for (let index = 0; index < data.length; index += 1) {
      const factor = result[index];
      if (factor === 0) {
        continue;
      }
      generator.forEach((coefficient, generatorIndex) => {
        result[index + generatorIndex] ^= gfMultiply(coefficient, factor);
      });
    }
    return result.slice(data.length);
  }

  function reedSolomonGenerator(degree) {
    let result = [1];
    for (let index = 0; index < degree; index += 1) {
      result = polynomialMultiply(result, [1, qrExp[index]]);
    }
    return result;
  }

  function polynomialMultiply(left, right) {
    const result = Array(left.length + right.length - 1).fill(0);
    left.forEach((leftCoefficient, leftIndex) => {
      right.forEach((rightCoefficient, rightIndex) => {
        result[leftIndex + rightIndex] ^= gfMultiply(leftCoefficient, rightCoefficient);
      });
    });
    return result;
  }

  window.TaterQr = { render };
})();
