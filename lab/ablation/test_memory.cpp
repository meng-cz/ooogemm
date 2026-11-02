#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <iostream>
#include <deque>
#include "experiment.hpp"

int main() {
    using namespace ablation;
    for (uint64_t mean : {4,32,128}) {
        for (const char* distribution : {"fixed","uniform","longtail"}) {
            Options opt; opt.mean=mean; opt.distribution=distribution; opt.seed=2;
            long double sum=0;
            for (uint32_t a=0;a<65536;++a) {
                auto delay=sample_delay(opt,a,0);
                if(delay!=sample_delay(opt,a,0)) throw std::runtime_error("non-reproducible sample");
                if(opt.distribution=="uniform" && (delay<1 || delay>2*mean-1)) throw std::runtime_error("uniform out of range");
                if(opt.distribution=="longtail" && delay!=1 && delay!=16*mean-15) throw std::runtime_error("longtail out of range");
                sum+=delay;
            }
            if(std::fabs(double(sum/65536)-mean) > mean*.04) throw std::runtime_error("empirical mean outside tolerance");
        }
    }
    Options opt; opt.distribution="uniform"; opt.mean=32;
    Stats first, reordered;
    uint64_t a=first.request(opt,123,0,10), b=first.request(opt,456,1,11);
    uint64_t rb=reordered.request(opt,456,0,10), ra=reordered.request(opt,123,1,11);
    if(a!=ra || b!=rb) throw std::runtime_error("samples depend on issue order");
    bool rejected=false;
    try { first.request(opt,789,0,12); } catch(const std::runtime_error&) { rejected=true; }
    if(!rejected) throw std::runtime_error("live ID reuse accepted");
    first.response(1,100); first.response(0,101);
    rejected=false;
    try {first.response(0,102);} catch(const std::runtime_error&) {rejected=true;}
    if(!rejected || first.requests!=first.responses || first.reordered_responses!=1) throw std::runtime_error("response accounting");
    // A newer ready response can bypass an unready older one; a selected
    // response must remain stable under backpressure even as the older one
    // becomes eligible. This is the selector used by the actual harnesses.
    struct Beat {uint64_t due; unsigned id;};
    std::deque<Beat> pending{{100,7},{10,8}};
    ResponseSelector selector;
    if(selector.select(pending,9)!=-1) throw std::runtime_error("early response");
    if(selector.select(pending,10)!=1) throw std::runtime_error("ready response did not bypass");
    if(selector.select(pending,101)!=1 || pending[selector.held].id!=8)
        throw std::runtime_error("response changed while backpressured");
    pending.erase(pending.begin()+selector.held); selector.accepted();
    if(selector.select(pending,102)!=0 || pending[selector.held].id!=7)
        throw std::runtime_error("response was lost");
    // Distinct occurrences of one address do not share a constant sample.
    bool changed=false;
    for(unsigned i=1;i<64;++i) changed |= sample_delay(opt,123,i)!=sample_delay(opt,123,0);
    if(!changed) throw std::runtime_error("occurrence was not part of sample key");
    std::cout << "PASS deterministic address-keyed delays, distributions, ID lifetime and response accounting\n";
}
