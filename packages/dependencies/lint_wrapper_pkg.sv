// Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date: 24/04/2024
//
// Description: Auiliary package with constants and typedefs for linting.

 `ifndef LINT_WRAPPER
 `define LINT_WRAPPER

 `include "axi_pkg.sv"

package lint_wrapper;

    localparam UserWidth    = 1;
    localparam AddrWidth    = 64;
    localparam DataWidth    = 64;
    localparam StrbWidth    = DataWidth / 8;
    localparam IdWidth      = 4;
    localparam IdWidthSlv   = 6;

    typedef logic [IdWidth-1:0]     id_t;
    typedef logic [IdWidthSlv-1:0]  id_slv_t;
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;

    // AXI DVM extension
    localparam DevIDWidth   = 24;
    localparam ProcIDWidth  = 20;

    typedef logic [DevIDWidth-1:0]  iommu_sid_t;
    typedef logic                   iommu_ssidv_t;
    typedef logic [ProcIDWidth-1:0] iommu_ssid_t;

    // AW Channel
    typedef struct packed {
        id_t              id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        axi_pkg::atop_t   atop;
        user_t            user;
    } aw_chan_t;

    // AW Channel - Slave
    typedef struct packed {
        id_slv_t          id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        axi_pkg::atop_t   atop;
        user_t            user;
    } aw_chan_slv_t;

    // AW Channel - AXI DVM extension for SMMU
    typedef struct packed {
        id_t              id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        axi_pkg::atop_t   atop;
        user_t            user;
        iommu_sid_t         stream_id;
        iommu_ssidv_t       ss_id_valid;
        iommu_ssid_t        substream_id;
    } aw_chan_iommu_t;

    // W Channel - AXI4 doesn't define a wid
    typedef struct packed {
        data_t data;
        strb_t strb;
        logic  last;
        user_t user;
    } w_chan_t;

    // B Channel
    typedef struct packed {
        id_t            id;
        axi_pkg::resp_t resp;
        user_t          user;
    } b_chan_t;

    // B Channel - Slave
    typedef struct packed {
        id_slv_t        id;
        axi_pkg::resp_t resp;
        user_t          user;
    } b_chan_slv_t;

    // AR Channel
    typedef struct packed {
        id_t             id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        user_t            user;
    } ar_chan_t;

    // AR Channel - Slave
    typedef struct packed {
        id_slv_t          id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        user_t            user;
    } ar_chan_slv_t;

    // AR Channel - AXI DVM extension for SMMU
    typedef struct packed {
        id_t              id;
        addr_t            addr;
        axi_pkg::len_t    len;
        axi_pkg::size_t   size;
        axi_pkg::burst_t  burst;
        logic             lock;
        axi_pkg::cache_t  cache;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
        user_t            user;
        iommu_sid_t         stream_id;
        iommu_ssidv_t       ss_id_valid;
        iommu_ssid_t        substream_id;
    } ar_chan_iommu_t;

    // R Channel
    typedef struct packed {
        id_t            id;
        data_t          data;
        axi_pkg::resp_t resp;
        logic           last;
        user_t          user;
    } r_chan_t;

    // R Channel - Slave
    typedef struct packed {
        id_slv_t        id;
        data_t          data;
        axi_pkg::resp_t resp;
        logic           last;
        user_t          user;
    } r_chan_slv_t;

    // Request/Response structs
    typedef struct packed {
        aw_chan_t aw;
        logic     aw_valid;
        w_chan_t  w;
        logic     w_valid;
        logic     b_ready;
        ar_chan_t ar;
        logic     ar_valid;
        logic     r_ready;
    } req_t;

    typedef struct packed {
        logic     aw_ready;
        logic     ar_ready;
        logic     w_ready;
        logic     b_valid;
        b_chan_t  b;
        logic     r_valid;
        r_chan_t  r;
    } resp_t;

    typedef struct packed {
        aw_chan_slv_t aw;
        logic         aw_valid;
        w_chan_t      w;
        logic         w_valid;
        logic         b_ready;
        ar_chan_slv_t ar;
        logic         ar_valid;
        logic         r_ready;
    } req_slv_t;

    typedef struct packed {
        logic         aw_ready;
        logic         ar_ready;
        logic         w_ready;
        logic         b_valid;
        b_chan_slv_t  b;
        logic         r_valid;
        r_chan_slv_t  r;
    } resp_slv_t;

    // AXI DVM extension for SMMU
    typedef struct packed {
        aw_chan_iommu_t   aw;
        logic           aw_valid;
        w_chan_t        w;
        logic           w_valid;
        logic           b_ready;
        ar_chan_iommu_t   ar;
        logic           ar_valid;
        logic           r_ready;
    } req_iommu_t;

endpackage

`endif
