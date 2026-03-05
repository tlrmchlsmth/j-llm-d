#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>

#include <chrono>
#include <iostream>
#include <vector>
#include <string>
#include <cstring>

FILE* fout_fd;
void output_nic_counters(FILE* fout_fd);
int polled_count = 0;

void sig_handler(int signum) {
    if (signum == SIGINT || signum == SIGTERM) {
        printf("\nSignal %d received\n", signum);
        printf("Polled %d samples\n", polled_count);
        output_nic_counters(fout_fd);
        fclose(fout_fd);
        exit(0);
    }
}

#define MAX_SAMPLES 20000000

#define NO_CHANGE_STREAK_THRESHOLD 20

int POLL_INTERVAL_US = 0;

typedef struct nic_counter_sample
{
    std::chrono::time_point<std::chrono::high_resolution_clock> timestamp;
    char tx_byte_counter[16];
    char rx_byte_counter[16];

    public:
    nic_counter_sample() {
        timestamp = std::chrono::time_point<std::chrono::high_resolution_clock>::min();
        memset(tx_byte_counter, 0, 16);
        memset(rx_byte_counter, 0, 16);
    }
} nic_counter_sample;

std::vector<nic_counter_sample> nic_counter_samples(MAX_SAMPLES);


void get_nic_counters(nic_counter_sample* sample, int tx_fd, int rx_fd) {
    if (lseek(tx_fd, 0, SEEK_SET) == -1) {
        std::cerr << "Failed to rewind tx fd" << std::endl;
        return;
    }
    if (lseek(rx_fd, 0, SEEK_SET) == -1) {
        std::cerr << "Failed to rewind rx fd" << std::endl;
        return;
    }

    sample->timestamp = std::chrono::high_resolution_clock::now();
    read(tx_fd, sample->tx_byte_counter, 16);
    read(rx_fd, sample->rx_byte_counter, 16);
}

void output_nic_counters(FILE* fout_fd) {

    bool first_change_detected = false;
    int no_change_streak = 0;
    bool skip_output = false;

    fprintf(fout_fd, "timestamp\ttx_byte_counter\trx_byte_counter\n");

    nic_counter_sample *prev_sample = &nic_counter_samples[0];

    for (int i = 1; i < polled_count; i++) {
        nic_counter_sample *curr_sample = &nic_counter_samples[i];

        // Counters are in 32-bit double words; multiply by 4 for bytes
        // https://enterprise-support.nvidia.com/s/article/understanding-mlx5-linux-counters-and-status-parameters
        long int prev_tx_counter = std::stol(prev_sample->tx_byte_counter) * 4;
        long int prev_rx_counter = std::stol(prev_sample->rx_byte_counter) * 4;
        long int curr_tx_counter = std::stol(curr_sample->tx_byte_counter) * 4;
        long int curr_rx_counter = std::stol(curr_sample->rx_byte_counter) * 4;

        long int prev_timestamp = prev_sample->timestamp.time_since_epoch().count();
        long int curr_timestamp = curr_sample->timestamp.time_since_epoch().count();

        if(!first_change_detected) {
            if (curr_tx_counter != prev_tx_counter || curr_rx_counter != prev_rx_counter) {
                first_change_detected = true;
                no_change_streak = 0;
                fprintf(fout_fd, "%ld\t%ld\t%ld\n", prev_timestamp, prev_tx_counter, prev_rx_counter);
                fprintf(fout_fd, "%ld\t%ld\t%ld\n", curr_timestamp, curr_tx_counter, curr_rx_counter);
            }
        }
        else {
            if (curr_tx_counter == 0 || curr_rx_counter == 0) {
                break;
            }

            skip_output = false;

            if (curr_tx_counter == prev_tx_counter && curr_rx_counter == prev_rx_counter) {
                no_change_streak++;
                if (no_change_streak > NO_CHANGE_STREAK_THRESHOLD) {
                    first_change_detected = false;
                    skip_output = true;
                }
            }
            else {
                no_change_streak = 0;
            }

            if (!skip_output){
                fprintf(fout_fd, "%ld\t%ld\t%ld\n", curr_timestamp, curr_tx_counter, curr_rx_counter);
            }
        }

        prev_sample = curr_sample;
    }
}

int main(int argc, char* argv[]) {

    if (argc < 3 || argc > 4) {
        std::cerr << "Usage: " << argv[0] << " <mlx_dev> <output_file> [poll_interval_us]" << std::endl;
        std::cerr << "Example: " << argv[0] << " mlx5_3 /tmp/nic_mlx5_3.tsv       # no sleep (max fidelity)" << std::endl;
        std::cerr << "         " << argv[0] << " mlx5_3 /tmp/nic_mlx5_3.tsv 100   # 100us between polls" << std::endl;
        return 1;
    }

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    char* mlx_dev = argv[1];
    char* output_file = argv[2];
    if (argc == 4) {
        POLL_INTERVAL_US = atoi(argv[3]);
    }

    const std::string tx_byte_counter_file = std::string("/sys/class/infiniband/") + mlx_dev + "/ports/1/counters/port_xmit_data";
    const std::string rx_byte_counter_file = std::string("/sys/class/infiniband/") + mlx_dev + "/ports/1/counters/port_rcv_data";

    printf("Polling %s (TX: %s, RX: %s)\n", mlx_dev, tx_byte_counter_file.c_str(), rx_byte_counter_file.c_str());
    if (POLL_INTERVAL_US > 0) {
        printf("MAX_SAMPLES=%d, POLL_INTERVAL=%dus, coverage=~%ds\n",
               MAX_SAMPLES, POLL_INTERVAL_US, MAX_SAMPLES * POLL_INTERVAL_US / 1000000);
    } else {
        printf("MAX_SAMPLES=%d, POLL_INTERVAL=0 (max fidelity, ~%ds at ~5us/sample)\n",
               MAX_SAMPLES, MAX_SAMPLES * 5 / 1000000);
    }

    std::fill(nic_counter_samples.begin(), nic_counter_samples.end(), nic_counter_sample());

    int tx_fd = open(tx_byte_counter_file.c_str(), O_RDONLY);
    int rx_fd = open(rx_byte_counter_file.c_str(), O_RDONLY);

    fout_fd = fopen(output_file, "w");
    if (fout_fd == NULL) {
        std::cerr << "Failed to open output file: " << output_file << std::endl;
        return 1;
    }
    if (tx_fd == -1) {
        std::cerr << "Failed to open: " << tx_byte_counter_file << std::endl;
        return 1;
    }
    if (rx_fd == -1) {
        std::cerr << "Failed to open: " << rx_byte_counter_file << std::endl;
        return 1;
    }

    printf("Polling started. Press Ctrl+C to stop and write output.\n");

    for (; polled_count < MAX_SAMPLES; polled_count++) {
        get_nic_counters(&nic_counter_samples[polled_count], tx_fd, rx_fd);
        if (POLL_INTERVAL_US > 0) usleep(POLL_INTERVAL_US);
    }

    printf("Buffer full (%d samples). Writing output.\n", polled_count);
    output_nic_counters(fout_fd);

    close(tx_fd);
    close(rx_fd);
    fclose(fout_fd);

    return 0;
}
