"""Audio conversion service with proper streaming support"""

import struct
from fractions import Fraction
from io import BytesIO
from typing import Optional

import av
import numpy as np
import soundfile as sf
from loguru import logger


class _AudioTempoFilter:
    """Maintain a pitch-preserving tempo filter across streamed audio chunks."""

    def __init__(self, atempo: float):
        self.atempo = atempo
        self.graph = None
        self.source = None
        self.sink = None

    def _factors(self) -> list[float]:
        remaining = self.atempo
        factors = []
        while remaining < 0.5:
            factors.append(0.5)
            remaining /= 0.5
        while remaining > 2.0:
            factors.append(2.0)
            remaining /= 2.0
        factors.append(remaining)
        return factors

    def _initialize(self, frame: av.AudioFrame) -> None:
        self.graph = av.filter.Graph()
        self.source = self.graph.add_abuffer(
            sample_rate=frame.sample_rate,
            format=frame.format.name,
            layout=frame.layout.name,
            time_base=frame.time_base,
        )
        previous = self.source

        for factor in self._factors():
            tempo = self.graph.add("atempo", f"{factor:.10g}")
            previous.link_to(tempo)
            previous = tempo

        self.sink = self.graph.add("abuffersink")
        previous.link_to(self.sink)
        self.graph.configure()

    def _drain(self) -> list[av.AudioFrame]:
        frames = []
        while True:
            try:
                frames.append(self.sink.pull())
            except (BlockingIOError, EOFError):
                break
        return frames

    def push(self, frame: av.AudioFrame) -> list[av.AudioFrame]:
        if self.graph is None:
            self._initialize(frame)
        self.source.push(frame)
        return self._drain()

    def flush(self) -> list[av.AudioFrame]:
        if self.graph is None:
            return []
        self.source.push(None)
        return self._drain()


class StreamingAudioWriter:
    """Handles streaming audio format conversions"""

    def __init__(
        self, format: str, sample_rate: int, channels: int = 1, atempo: float = 1.0
    ):
        if not 0.25 <= atempo <= 4.0:
            raise ValueError("atempo must be between 0.25 and 4.0")

        self.format = format.lower()
        self.sample_rate = sample_rate
        self.channels = channels
        self.atempo = atempo
        self.bytes_written = 0
        self.input_pts = 0
        self.output_pts = 0
        self.tempo_filter = _AudioTempoFilter(atempo) if atempo != 1.0 else None

        codec_map = {
            "wav": "pcm_s16le",
            "mp3": "mp3",
            "opus": "libopus",
            "flac": "flac",
            "aac": "aac",
        }
        # Format-specific setup
        if self.format in ["wav", "flac", "mp3", "pcm", "aac", "opus"]:
            if self.format != "pcm":
                self.output_buffer = BytesIO()
                container_options = {}
                # Try disabling Xing VBR header for MP3 to fix iOS timeline reading issues
                if self.format == "mp3":
                    # Disable Xing VBR header
                    container_options = {"write_xing": "0"}
                    logger.debug("Disabling Xing VBR header for MP3 encoding.")

                self.container = av.open(
                    self.output_buffer,
                    mode="w",
                    format=self.format if self.format != "aac" else "adts",
                    options=container_options,  # Pass options here
                )
                self.stream = self.container.add_stream(
                    codec_map[self.format],
                    rate=self.sample_rate,
                    layout="mono" if self.channels == 1 else "stereo",
                )
                # Set bit_rate only for codecs where it's applicable and useful
                if self.format in ["mp3", "aac", "opus"]:
                    self.stream.bit_rate = 128000
        else:
            raise ValueError(
                f"Unsupported format: {self.format}"
            )  # Use self.format here

    def close(self):
        if hasattr(self, "container"):
            self.container.close()

        if hasattr(self, "output_buffer"):
            self.output_buffer.close()

    def _write_frames(self, frames: list[av.AudioFrame]) -> bytes:
        pcm_chunks = []
        for frame in frames:
            frame.pts = self.output_pts
            frame.time_base = Fraction(1, self.sample_rate)
            self.output_pts += frame.samples

            if self.format == "pcm":
                pcm_chunks.append(frame.to_ndarray().reshape(-1).tobytes())
                continue

            packets = self.stream.encode(frame)
            for packet in packets:
                self.container.mux(packet)

        if self.format == "pcm":
            return b"".join(pcm_chunks)

        data = self.output_buffer.getvalue()
        self.output_buffer.seek(0)
        self.output_buffer.truncate(0)
        return data

    def write_chunk(
        self, audio_data: Optional[np.ndarray] = None, finalize: bool = False
    ) -> bytes:
        """Write a chunk of audio data and return bytes in the target format.

        Args:
            audio_data: Audio data to write, or None if finalizing
            finalize: Whether this is the final write to close the stream
        """

        if finalize:
            filtered_frames = self.tempo_filter.flush() if self.tempo_filter else []
            filtered_data = self._write_frames(filtered_frames)

            if self.format != "pcm":
                # Flush stream encoder
                packets = self.stream.encode(None)
                for packet in packets:
                    self.container.mux(packet)

                # ogg writes its last audio page during close, read after; other muxers only seek back to patch headers at pos 0 of the truncated buffer, read first (#497)
                if self.format == "opus":
                    self.container.close()
                    data = self.output_buffer.getvalue()
                else:
                    data = self.output_buffer.getvalue()
                    self.container.close()
                logger.debug("Closed container, finalize complete.")

                self.output_buffer.close()
                return filtered_data + data
            return filtered_data

        if audio_data is None or len(audio_data) == 0:
            return b""

        if self.format == "pcm" and self.tempo_filter is None:
            return audio_data.tobytes()

        frame = av.AudioFrame.from_ndarray(
            audio_data.reshape(1, -1),
            format="s16",
            layout="mono" if self.channels == 1 else "stereo",
        )
        frame.sample_rate = self.sample_rate
        frame.pts = self.input_pts
        self.input_pts += frame.samples

        if self.tempo_filter:
            frame.time_base = Fraction(1, self.sample_rate)
            frames = self.tempo_filter.push(frame)
        else:
            frames = [frame]

        return self._write_frames(frames)
