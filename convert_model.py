"""
Converts intfloat/multilingual-e5-small to CoreML for DocumentBrain.

Output
  DocumentBrain/AI/E5Small.mlpackage   — model (Xcode generates the `E5Small` class)
  DocumentBrain/AI/e5_vocab.tsv        — SentencePiece unigram vocab: "piece<TAB>score", line = token id

The exported model bakes in mean pooling + L2 normalisation, so the app receives a
ready-to-use 384-dim unit vector. Inputs accept sequence lengths 128, 256 or 512
(enumerated shapes, ANE-friendly); the Swift tokenizer pads to the smallest that fits.

Weights are compressed: the 250K x 384 word-embedding table to int4 (per-block, 32),
every other weight to int8 per-channel (~72 MB instead of ~470 MB fp32). Measured on
the retrieval benchmark this changes nothing (see eval/run_retrieval_eval.py).

Remember: e5 expects "query: " before questions and "passage: " before indexed text.
The app adds these prefixes in EmbeddingService.

Usage (macOS or Linux):
    pip install "torch<2.8" transformers coremltools huggingface_hub
    python convert_model.py
"""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from transformers import AutoModel
from huggingface_hub import hf_hub_download
import coremltools as ct
import coremltools.optimize.coreml as cto

MODEL_NAME = "intfloat/multilingual-e5-small"
AI_DIR = Path(__file__).resolve().parent / "DocumentBrain" / "AI"
MODEL_PATH = AI_DIR / "E5Small.mlpackage"
VOCAB_PATH = AI_DIR / "e5_vocab.tsv"
SEQ_LENGTHS = [128, 256, 512]


class EmbeddingModel(nn.Module):
    """Transformer + mean pooling over non-padding tokens + L2 normalisation."""

    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, input_ids, attention_mask):
        hidden = self.base(input_ids=input_ids, attention_mask=attention_mask)[0]  # torchscript=True returns a tuple
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
        return nn.functional.normalize(pooled, p=2, dim=1)


def export_vocab():
    tokenizer = json.loads(Path(hf_hub_download(MODEL_NAME, "tokenizer.json")).read_text(encoding="utf-8"))
    model = tokenizer["model"]
    assert model["type"] == "Unigram" and model["unk_id"] == 3
    lines = []
    for piece, score in model["vocab"]:
        assert "\t" not in piece and "\n" not in piece
        lines.append(f"{piece}\t{score:.6f}")
    VOCAB_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Vocab: {len(lines)} pieces → {VOCAB_PATH}")


def export_model():
    base = AutoModel.from_pretrained(MODEL_NAME, torchscript=True).eval()
    model = EmbeddingModel(base).eval()

    ids = torch.zeros(1, 512, dtype=torch.int32)
    mask = torch.ones(1, 512, dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(model, (ids, mask))
        assert traced(ids, mask).shape == (1, 384)

    shapes = ct.EnumeratedShapes(shapes=[[1, n] for n in SEQ_LENGTHS], default=[1, 512])
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=shapes, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shapes, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )

    config = cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                                  granularity="per_channel"),
        op_type_configs={
            "gather": cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4",
                                                  granularity="per_block", block_size=32),
        },
    )
    mlmodel = cto.linear_quantize_weights(mlmodel, config)

    mlmodel.short_description = (
        "multilingual-e5-small — multilingual retrieval embeddings (384-dim, L2-normalised). "
        "Prefix queries with 'query: ' and documents with 'passage: '."
    )
    mlmodel.save(str(MODEL_PATH))
    print(f"Model → {MODEL_PATH}")


if __name__ == "__main__":
    AI_DIR.mkdir(parents=True, exist_ok=True)
    export_vocab()
    export_model()
