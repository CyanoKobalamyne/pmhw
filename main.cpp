#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

#include "HostToPuppetmaster.h"
#include "PuppetmasterToHostIndication.h"

// Helper function equivalent to C++20 std::unordered_set::contains.
template <typename type>
bool set_contains(std::unordered_set<type> &set, type &key) {
    return set.find(key) != set.end();
}

// Handler for messages received from the FPGA
class PuppetmasterToHostIndication : public PuppetmasterToHostIndicationWrapper {
public:
    void transactionStarted(std::uint64_t tid, std::uint64_t timestamp) {
        printf("Started %02lx at %lu\n", tid, timestamp);
        fflush(stdout);
    }

    void transactionFinished(std::uint64_t tid, std::uint64_t timestamp) {
        printf("Finished %02lx at %lu\n", tid, timestamp);
        fflush(stdout);
    }

    PuppetmasterToHostIndication(unsigned int id)
        : PuppetmasterToHostIndicationWrapper(id) {}
};

int main(int argc, char **argv) {
    printf("Connectal setting up ...\n");
    fflush(stdout);

    HostToPuppetmasterProxy *fpga =
        new HostToPuppetmasterProxy(IfcNames_HostToPuppetmasterS2H);
    printf("Initialized the request interface to the FPGA\n");
    fflush(stdout);

    PuppetmasterToHostIndication puppetmasterToHost(
        IfcNames_PuppetmasterToHostIndicationH2S);
    printf("Initialized the indication interface\n");
    fflush(stdout);

    constexpr std::size_t numObjects = 16;
    std::vector<std::array<Object, numObjects>> tests;

    if (argc <= 1) {
        // No test files given, construct default test.
        printf("Loading default tests...");
        fflush(stdout);

        unsigned numTests = 4;
        unsigned maxScheduledObjects = 8;
        unsigned objSetSize = numObjects / 2;

        for (unsigned i = 0; i < numTests * maxScheduledObjects; i++) {
            std::array<Object, numObjects> objs;
            for (unsigned j = 0; j < objSetSize; j++) {
                objs[2 * j] = (Object){
                    .valid = 1,
                    .write = 0,
                    .object = objSetSize * i * 2 + j * 2,
                };
                objs[2 * j + 1] = (Object){
                    .valid = 1,
                    .write = 1,
                    .object = i % 4 == 0   ? objSetSize * i * 2 + j * 2 + 1
                              : i % 4 == 1 ? objSetSize * (i - i % 2) * 2 + j * 2 + 1
                              : i % 4 == 2 ? objSetSize * (i % 2) * 2 + j * 2 + 1
                                           : objSetSize * 2 + j * 2 + 1,
                };
            }
            tests.push_back(objs);
        }
    } else {
        // Load each input file given into tests.
        for (int i = 1; i < argc; i++) {
            printf("Loading tests from: %s\n", argv[i]);
            fflush(stdout);

            // Open input file.
            std::ifstream source;
            source.open(argv[i]);
            if (!source.is_open()) {
                printf("File doesn't exist.\n");
                fflush(stdout);
                return 1;
            }

            // Parse header for location of read and write object fields.
            std::string header;
            if (!std::getline(source, header)) {
                printf("No header found in file.\n");
                fflush(stdout);
                return 2;
            }
            std::unordered_set<std::size_t> readIndices;
            std::unordered_set<std::size_t> writeIndices;
            std::stringstream headerBuffer(header);
            std::string label;
            for (std::size_t i = 0; std::getline(headerBuffer, label, ','); i++) {
                if (label.find("Read object") == 0) {
                    readIndices.insert(i);
                } else if (label.find("Written object") == 0) {
                    writeIndices.insert(i);
                }
            }

            // Parse content lines.
            std::string line;
            while (std::getline(source, line)) {
                std::array<Object, numObjects> objs;

                // Parse each comma-separated value in line.
                std::stringstream lineBuffer(line);
                std::string value;
                for (std::size_t i = 0;
                     i < numObjects && std::getline(lineBuffer, value, ','); i++) {
                    if (value.length() != 0 && (set_contains(readIndices, i) ||
                                                set_contains(writeIndices, i))) {
                        ObjectAddress address;
                        try {
                            address = std::stoul(value);
                        } catch (const std::invalid_argument &) {
                            printf("Not an address: \"%s\"\n", value.c_str());
                            fflush(stdout);
                            return 3;
                        } catch (const std::out_of_range &) {
                            printf("Out of range: %s\n", value.c_str());
                            fflush(stdout);
                            return 4;
                        }
                        objs[i] = (Object){.valid = 1,
                                           .write = set_contains(writeIndices, i),
                                           .object = address};
                    }
                }
                tests.push_back(objs);
            }
            source.close();
        }
    }

    // Run tests.
    for (std::size_t i = 0; i < tests.size(); i++) {
        auto &objs = tests[i];
        fpga->enqueueTransaction(i, objs[0], objs[1], objs[2], objs[3], objs[4],
                                 objs[5], objs[6], objs[7], objs[8], objs[9], objs[10],
                                 objs[11], objs[12], objs[13], objs[14], objs[15]);
    }

    while (true) {
        // Wait for simulation.
    }
}
