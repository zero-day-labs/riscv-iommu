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
// Date: 12/10/2022
//
// Description: IOMMU Register field package. Contains SW access permissions.
//
// Disclaimer:  This file was generated using LowRISC `reggen` tool. Edit at your own risk.

`ifndef IOMMU_FIELD_PKG_DEF
`define IOMMU_FIELD_PKG_DEF

package iommu_field_pkg;

    // SW access permissions specifier
    typedef enum logic [2:0] { 
        SwAccessRW  = 3'd0, // Read-write
        SwAccessRO  = 3'd1, // Read-only
        SwAccessWO  = 3'd2, // Write-only
        SwAccessW1C = 3'd3, // Write 1 to clear
        SwAccessW1S = 3'd4, // Write 1 to set
        SwAccessW0C = 3'd5, // Write 0 to clear
        SwAccessRC  = 3'd6  // Read to clear. Do not use, only exists for compatibility.
    } sw_access_e;

endpackage

`endif
