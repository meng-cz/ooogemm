#pragma once
// Shared by the two dedicated ablation harness builds; legacy builds exclude it.
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <cmath>
#include <map>
#include <set>
#include <utility>
#include <limits>

namespace ablation {
constexpr unsigned reason_count = 16;
constexpr const char* reasons[reason_count] = {
    "active", "wait_a", "wait_b", "wait_ab", "gemm_head_of_line",
    "a_physical_full", "b_physical_full", "acc_physical_full",
    "acc_reuse_gap", "issue_port", "operand_delivery", "static_wave",
    "output_reclaim", "control", "pipeline_fill", "pipeline_drain"
};
struct Options {
    std::string distribution = "fixed";
    uint64_t mean = 4, seed = 1;
    std::string stats_path, trace_path;
};
inline bool parse_option(const std::string& arg, Options& opt) {
    const auto eq = arg.find('=');
    if (eq == std::string::npos) return false;
    const std::string name = arg.substr(0, eq), value = arg.substr(eq+1);
    if (name == "--delay-distribution") opt.distribution = value;
    else if (name == "--delay-mean") opt.mean = std::stoull(value);
    else if (name == "--delay-seed") opt.seed = std::stoull(value);
    else if (name == "--ablation-stats") opt.stats_path = value;
    else if (name == "--cycle-trace") opt.trace_path = value;
    else return false;
    return true;
}
inline uint64_t mix(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
// Stateless, address/occurrence-keyed samples. Rejection avoids modulo bias.
inline uint64_t sample_delay(const Options& opt, uint32_t address, uint64_t occurrence) {
    if (opt.mean < 1 || opt.mean > UINT32_MAX / 16)
        throw std::runtime_error("delay mean outside supported range");
    if (opt.distribution == "fixed") return opt.mean;
    uint64_t random = mix(mix(opt.seed ^ UINT64_C(0x91e10da5c79e7b1d)) ^
                          mix(uint64_t(address) ^ UINT64_C(0xd1b54a32d192ed03)) ^
                          mix(occurrence ^ UINT64_C(0xabc98388fb8fac03)));
    if (opt.distribution == "longtail") return (random & 15) ? 1 : 16*opt.mean-15;
    if (opt.distribution != "uniform") throw std::runtime_error("unknown delay distribution");
    const uint64_t bound = 2*opt.mean-1;
    const uint64_t threshold = -bound % bound;
    while (random < threshold) random = mix(random);
    return 1 + random % bound;
}
// Select at most one eligible beat and retain it until the caller reports a
// handshake. Queue entries remain in place until that handshake.
struct ResponseSelector {
    int held = -1;
    template<class Queue>
    int select(const Queue& queue, uint64_t cycle) {
        if (held >= 0) return held;
        for (size_t i=0; i<queue.size(); ++i) {
            if (queue[i].due <= cycle) return held=static_cast<int>(i);
        }
        return -1;
    }
    void accepted() { held=-1; }
};

struct Histogram {
    std::map<uint64_t, uint64_t> bins;
    uint64_t count = 0;
    long double sum = 0;
    void add(uint64_t n) { ++bins[n]; ++count; sum += n; }
    uint64_t quantile(double q) const {
        const uint64_t target = static_cast<uint64_t>(std::ceil(count*q));
        uint64_t seen = 0;
        for (const auto& entry : bins) { seen += entry.second; if (seen >= target) return entry.first; }
        return 0;
    }
    void json(std::ostream& out) const {
        out << "{\"count\":" << count << ",\"mean\":" << (count ? sum/count : 0)
            << ",\"p50\":" << quantile(.5) << ",\"p95\":" << quantile(.95)
            << ",\"p99\":" << quantile(.99) << ",\"max\":" << quantile(1) << '}';
    }
};
struct Phase {
    uint64_t cycles=0, lane_active=0, mac_active=0;
    std::array<uint64_t,reason_count> lane_idle{}, mac_idle{};
};
struct Stats {
    uint64_t cycles=0, lane_active=0, mac_active=0, whole_idle=0;
    uint64_t requests=0, responses=0, peak_outstanding=0, reordered_responses=0;
    uint64_t output_hash=0, next_request=0;
    std::array<uint64_t,reason_count> lane_idle{}, mac_idle{}, blockers{};
    std::array<Phase,3> phases{};
    Histogram intended, actual;
    std::map<uint32_t,uint64_t> occurrences;
    std::map<uint32_t,std::pair<uint64_t,uint64_t>> live;
    std::set<uint32_t> stores;
    std::map<std::pair<uint32_t,uint32_t>,uint64_t> blocks;
    std::ofstream trace;
    bool trace_opened=false;
    uint64_t request(const Options& opt, uint32_t addr, uint32_t id, uint64_t cycle) {
        if (live.count(id)) throw std::runtime_error("request ID reused before response");
        live[id] = {cycle,next_request++};
        const uint64_t delay = sample_delay(opt,addr,occurrences[addr]++);
        intended.add(delay);
        ++requests;
        peak_outstanding=std::max<uint64_t>(peak_outstanding,live.size());
        return delay;
    }
    void response(uint32_t id, uint64_t cycle) {
        auto it=live.find(id);
        if (it==live.end()) throw std::runtime_error("duplicate or unknown response ID");
        for (const auto& pending:live) {
            if (pending.second.second < it->second.second) { ++reordered_responses; break; }
        }
        actual.add(cycle-it->second.first);
        live.erase(it);
        ++responses;
    }
    template<class DUT>
    void store(const DUT& dut, uint32_t addr, unsigned words) {
        if (!stores.insert(addr).second) throw std::runtime_error("duplicate store beat address");
        // Address-keyed XOR is independent of the store issue order.
        for (unsigned w=0; w<words; ++w)
            output_hash ^= mix((uint64_t(addr)<<32) ^ mix(w) ^ uint32_t(dut.store_mem_wr_data_o[w]));
    }
    template<class DUT>
    void sample(const DUT& dut, const Options& opt, uint64_t cycle,
                unsigned lanes, unsigned width, uint64_t expected_mac) {
        unsigned phase=(mac_active==0) ? 0 : ((mac_active>=expected_mac) ? 2 : 1);
        auto& p=phases[phase];
        ++cycles; ++p.cycles;
        lane_active+=dut.perf_lane_active_o; p.lane_active+=dut.perf_lane_active_o;
        mac_active+=dut.perf_mac_active_o; p.mac_active+=dut.perf_mac_active_o;
        whole_idle+=(dut.perf_mac_active_o==0);
        uint64_t lane_total=dut.perf_lane_active_o, mac_total=dut.perf_mac_active_o;
        for (unsigned r=0;r<reason_count;++r) {
            lane_idle[r]+=dut.perf_lane_idle_o[r]; p.lane_idle[r]+=dut.perf_lane_idle_o[r];
            mac_idle[r]+=dut.perf_mac_idle_o[r]; p.mac_idle[r]+=dut.perf_mac_idle_o[r];
            blockers[r]+=(dut.perf_blockers_o>>r)&1;
            lane_total+=dut.perf_lane_idle_o[r]; mac_total+=dut.perf_mac_idle_o[r];
        }
        if (lane_total!=lanes || mac_total!=uint64_t(lanes)*width*width ||
            dut.perf_mac_idle_o[0] || dut.perf_lane_idle_o[0])
            throw std::runtime_error("performance counter conservation failure");
        if (dut.perf_block_fire_o) ++blocks[{dut.perf_block_m_o,dut.perf_block_n_o}];
        if (!opt.trace_path.empty()) {
            if (!trace_opened) {
                trace.open(opt.trace_path);
                if (!trace) throw std::runtime_error("cannot open cycle trace");
                trace << "cycle,phase,lane_active,mac_active,blockers";
                for (unsigned r=1;r<reason_count;++r) trace << ",lane_" << reasons[r] << ",mac_" << reasons[r];
                trace << '\n'; trace_opened=true;
            }
            trace << cycle << ',' << phase << ',' << dut.perf_lane_active_o << ','
                  << dut.perf_mac_active_o << ',' << dut.perf_blockers_o;
            for (unsigned r=1;r<reason_count;++r) trace << ',' << dut.perf_lane_idle_o[r] << ',' << dut.perf_mac_idle_o[r];
            trace << '\n';
        }
    }
    static void reason_json(std::ostream& out, const std::array<uint64_t,reason_count>& a) {
        out << '{';
        for (unsigned r=1;r<reason_count;++r) { if(r>1) out << ','; out << '"' << reasons[r] << "\":" << a[r]; }
        out << '}';
    }
    void write(const Options& opt, uint64_t elapsed, uint64_t expected_mac,
               double throughput, double latency, double input_util, double output_util) {
        if (cycles!=elapsed || mac_active!=expected_mac || requests!=responses || !live.empty())
            throw std::runtime_error("incomplete performance window or memory transactions");
        if (opt.stats_path.empty()) throw std::runtime_error("ablation build requires --ablation-stats");
        std::ofstream out(opt.stats_path);
        if (!out) throw std::runtime_error("cannot open ablation stats");
        out << std::setprecision(12) << "{\"cycles\":" << cycles << ",\"throughput\":" << throughput
            << ",\"latency\":" << latency << ",\"input_bus_util\":" << input_util
            << ",\"output_bus_util\":" << output_util << ",\"lane_active\":" << lane_active
            << ",\"mac_active\":" << mac_active << ",\"whole_array_idle_cycles\":" << whole_idle
            << ",\"requests\":" << requests << ",\"responses\":" << responses
            << ",\"peak_outstanding\":" << peak_outstanding << ",\"reordered_responses\":" << reordered_responses
            << ",\"output_hash\":\"" << output_hash << "\",\"store_beats\":" << stores.size()
            << ",\"sampled_delay\":"; intended.json(out);
        out << ",\"observed_delay\":"; actual.json(out);
        out << ",\"lane_idle\":"; reason_json(out,lane_idle);
        out << ",\"mac_idle\":"; reason_json(out,mac_idle);
        out << ",\"blocker_cycles\":"; reason_json(out,blockers);
        out << ",\"phases\":{";
        const char* phase_names[]={"warmup","steady","drain"};
        for (unsigned phase=0;phase<3;++phase) {
            if(phase) out << ',';
            const auto& p=phases[phase];
            out << '"' << phase_names[phase] << "\":{\"cycles\":" << p.cycles
                << ",\"lane_active\":" << p.lane_active << ",\"mac_active\":" << p.mac_active << ",\"lane_idle\":";
            reason_json(out,p.lane_idle); out << ",\"mac_idle\":"; reason_json(out,p.mac_idle); out << '}';
        }
        out << "},\"blocks\":[";
        bool first=true;
        for (const auto& entry:blocks) {
            if(!first) out << ','; first=false;
            out << "{\"m\":" << entry.first.first << ",\"n\":" << entry.first.second << ",\"count\":" << entry.second << '}';
        }
        out << "]}\n";
        out.flush();
        if (!out) throw std::runtime_error("failed to write ablation stats");
    }
};
} // namespace ablation
