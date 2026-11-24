"""Build-time check: the sdpa varlen attention added by pascal.patch matches naive attention."""
import torch

from trellis2.modules.sparse import config
from trellis2.modules.sparse.attention.sdpa_varlen import sdpa_varlen

assert config.ATTN == "sdpa", f"ATTN_BACKEND=sdpa not picked up, got {config.ATTN}"


def naive(q, k, v, q_lens, kv_lens):
    out, qs, ks = [], 0, 0
    for lq, lk in zip(q_lens, kv_lens):
        qi, ki, vi = q[qs:qs + lq], k[ks:ks + lk], v[ks:ks + lk]          # [L, H, C]
        att = torch.einsum("qhc,khc->hqk", qi, ki) / qi.shape[-1] ** 0.5
        out.append(torch.einsum("hqk,khc->qhc", att.softmax(-1), vi))
        qs, ks = qs + lq, ks + lk
    return torch.cat(out)


torch.manual_seed(0)
H, C, CV = 4, 32, 16
cases = [
    ([37], [37]),                   # single sequence (full attention, batch 1)
    ([5, 64, 1, 17], [5, 64, 1, 17]),  # windowed self-attention
    ([3, 9, 30], [12, 2, 25]),      # cross-attention, different lengths
]
for q_lens, kv_lens in cases:
    q = torch.randn(sum(q_lens), H, C, dtype=torch.float64)
    k = torch.randn(sum(kv_lens), H, C, dtype=torch.float64)
    v = torch.randn(sum(kv_lens), H, CV, dtype=torch.float64)
    got = sdpa_varlen(q, k, v, q_lens, torch.tensor(kv_lens))
    ref = naive(q, k, v, q_lens, kv_lens)
    assert got.shape == ref.shape, (got.shape, ref.shape)
    err = (got - ref).abs().max().item()
    assert err < 1e-9, f"{q_lens}/{kv_lens}: max abs error {err}"
    print(f"sdpa_varlen ok  q={q_lens} kv={kv_lens}  max|err|={err:.2e}")
