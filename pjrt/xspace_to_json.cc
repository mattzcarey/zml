/// Convert a profiler session produced by a pjrt backend and convert it to the "standard" trace.json
/// format supported by several tools like perfetto.ui.
#include <fstream>
#include <filesystem>
#include <string>
#include "tsl/profiler/convert/trace_events_to_json.h"
#include "tsl/profiler/convert/xplane_to_trace_events.h"
#include "tsl/profiler/convert/post_process_single_host_xplane.h"
#include "tsl/profiler/protobuf/xplane.pb.h"

int main(int argc, char *argv[]) {
    char* filename = argv[1];
    if (!std::filesystem::exists(filename)) {
        std::cerr << "File not found " << filename << "!" << std::endl;
        return false;
    }
    if (std::filesystem::file_size(filename) == 0) {
        std::cerr << "Empty file " << filename << "!" << std::endl;
        return false;
    }
    tensorflow::profiler::XSpace xspace;
    {
        std::ifstream input(filename, std::ios::in | std::ios::binary);
        if (!xspace.ParseFromIstream(&input)) {
            std::cerr << "Error while parsing xspace !" << std::endl;
            return false;
        }
    }
    std::int64_t events = 0;
    for (auto plane: xspace.planes()) {
        for (auto line: plane.lines()) {
            events += line.events().size();
        }
    }
    std::cerr << "Found " << events << " events across " << xspace.planes().size() << " spaces." << std::endl;
    tsl::profiler::TraceContainer container =
        tsl::profiler::ConvertXSpaceToTraceContainer(xspace);
    std::cout << tsl::profiler::TraceContainerToJson(container) << std::endl;
    return true;
}
