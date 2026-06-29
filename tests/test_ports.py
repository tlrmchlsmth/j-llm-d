from jllmd.ports import derive_ports


def test_no_dp_has_one_port():
    ports = derive_ports(data_parallel_enabled=False, data_parallel_local_size=None)

    assert ports.public == [8000]
    assert ports.backend == [8000]
    assert ports.rank_count == 1


def test_dp_has_one_port_per_local_rank():
    ports = derive_ports(
        data_parallel_enabled=True,
        data_parallel_local_size=4,
        public_base=8000,
        backend_base=8200,
    )

    assert ports.public == [8000, 8001, 8002, 8003]
    assert ports.backend == [8200, 8201, 8202, 8203]
    assert ports.rank_count == 4
