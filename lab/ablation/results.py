"""Completion validation shared by resume, publishing and reporting."""
import json
import math
from pathlib import Path

from lab.ablation.core import REASONS, Hardware, validate_stats


def queue_layout(hw):
    slots = (hw.acc+hw.slot_acc_count-1)//hw.slot_acc_count
    beats = hw.width*max(1, hw.subtile_k*8//hw.load_data_width)
    outstanding = 1 << max(1, (beats-1).bit_length())
    dynamic = hw.mode != 'static'
    return {'scheduler_load_fifo_depth':16 if dynamic else None,
            'gemm_slots':slots if dynamic else None,
            'gemm_slot_fifo_depth':16 if dynamic else None,
            'gemm_slot_ready_buffers':1 if dynamic else None,
            'gemm_order_tracker_depth':slots*17 if hw.mode == 'dynamic_inorder' else None,
            'gemm_completion_tracking_depth':64 if dynamic else None,
            'load_outstanding_ids':outstanding,'load_uop_queue_depth':outstanding,
            'store_descriptor_fifo_depth':1 if dynamic else hw.acc,
            'store_payload_fifo_depth':2*(hw.width//hw.store_rows),
            'sa_buffers_per_lane':2}


def validate(metrics, spec):
    validate_stats(metrics, spec)
    required = {'cycles','throughput','latency','input_bus_util','output_bus_util',
                'lane_active','lane_idle','mac_active','mac_idle','phases',
                'requests','responses','store_beats','peak_outstanding',
                'reordered_responses','whole_array_idle_cycles','output_hash',
                'sampled_delay','observed_delay','blocker_cycles','blocks'}
    if not required.issubset(metrics):
        raise ValueError('missing required performance fields')
    cycles = metrics['cycles']
    for field in ('requests','responses','store_beats','peak_outstanding','reordered_responses','whole_array_idle_cycles'):
        if type(metrics[field]) is not int or metrics[field] < 0:
            raise ValueError('invalid transaction or cycle counter')
    if metrics['whole_array_idle_cycles'] > cycles or metrics['reordered_responses'] > metrics['responses']:
        raise ValueError('out-of-range counters')
    if set(metrics['phases']) != {'warmup','steady','drain'}:
        raise ValueError('missing measurement phase')
    for p in metrics['phases'].values():
        if any(type(p[k]) is not int or p[k] < 0 for k in ('cycles','lane_active','mac_active')):
            raise ValueError('invalid phase count')
        for name in ('lane_idle','mac_idle'):
            if set(p[name]) != set(REASONS) or any(type(v) is not int or v < 0 for v in p[name].values()):
                raise ValueError('invalid phase reasons')
    for field in ('sampled_delay','observed_delay'):
        h = metrics[field]
        if set(h) != {'count','mean','p50','p95','p99','max'} or h['count'] != metrics['requests']:
            raise ValueError('incomplete delay statistics')
        if any(not isinstance(v,(int,float)) or not math.isfinite(v) or v < 0 for v in h.values()):
            raise ValueError('invalid delay statistics')
    if set(metrics['blocker_cycles']) != set(REASONS) or any(type(v) is not int or not 0 <= v <= cycles for v in metrics['blocker_cycles'].values()):
        raise ValueError('invalid blocker counts')
    if not metrics['blocks'] or any(set(b) != {'m','n','count'} or any(type(v) is not int or v <= 0 for v in b.values()) for b in metrics['blocks']):
        raise ValueError('missing or invalid selected-block histogram')
    if sum(b['count'] for b in metrics['blocks']) != spec['count']:
        raise ValueError('incomplete block selection histogram')
    if not math.isclose(metrics['throughput'], spec['count']*1000/cycles, rel_tol=1e-9):
        raise ValueError('throughput disagrees with measurement window')
    if not isinstance(metrics['output_hash'],str) or not 0 <= int(metrics['output_hash']) < 2**64:
        raise ValueError('invalid output checksum')


def complete(path: Path, spec: dict) -> bool:
    try:
        result = json.loads(path.read_text())
        if result['status'] != 'complete' or result['spec'] != spec:
            return False
        if result['queue_layout'] != queue_layout(Hardware(**spec['hardware'])):
            return False
        validate(result['metrics'], spec)
        return True
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
        return False
