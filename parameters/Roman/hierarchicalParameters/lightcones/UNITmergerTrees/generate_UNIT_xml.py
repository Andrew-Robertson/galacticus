import argparse

def generate_unit_xml(n_files, output_filename):
    base_path = "/carnegie/nobackup/groups/dmtheory/mergerTrees/UNIT"
    prefix = "Tree_UNIT_001_SF10000_d"

    # Generate newline-separated list of file paths
    file_lines = "\n  ".join(
        f"{base_path}/{prefix}{i}.hdf5" for i in range(1, n_files + 1)
    )

    # Build the XML content
    xml_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Change a parameter file -->
<changes>
  <change type="update" path="mergerTreeConstructor/fileNames" value="{file_lines}
  "/>
</changes>
"""

    # Write to file
    with open(output_filename, "w") as f:
        f.write(xml_content)

    print(f" Wrote {n_files} file paths to {output_filename}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate UNIT XML file with specified number of merger tree paths.")
    parser.add_argument("n_files", type=int, help="Number of HDF5 tree files to include")
    parser.add_argument("output_filename", type=str, help="Output XML file name")

    args = parser.parse_args()
    generate_unit_xml(args.n_files, args.output_filename)
