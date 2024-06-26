# Create a resource group
resource "azurerm_resource_group" "my_project" {
  name     = local.resource_group_name
  location = local.location

  tags = {
    Owner = "htrung"
  }
}

# Create virtual network
resource "azurerm_virtual_network" "my_project-vnet" {
  name                = local.virtual_network_name
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.my_project.location
  resource_group_name = azurerm_resource_group.my_project.name
}

# Create subnet
resource "azurerm_subnet" "my_project-subnet" {
  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.my_project.name
  virtual_network_name = azurerm_virtual_network.my_project-vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Create public ip
resource "azurerm_public_ip" "my_project-publicip" {
  name                = local.public_ip_name
  resource_group_name = azurerm_resource_group.my_project.name
  location            = azurerm_resource_group.my_project.location
  allocation_method   = "Static"

  tags = {
    environment = "k8s-cluster"
  }
}

# Create NSG
resource "azurerm_network_security_group" "my_project-nsg" {
  name                = local.nsg_name
  location            = azurerm_resource_group.my_project.location
  resource_group_name = azurerm_resource_group.my_project.name

  security_rule {
    name                       = "allowallportin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "1-65535"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allowallportout"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "1-65535"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    environment = "k8s-cluster"
  }
}

# connect sercurity group to network interface
resource "azurerm_network_interface_security_group_association" "my_project-nsgtonic" {
  network_interface_id      = azurerm_network_interface.my_project-nic.id
  network_security_group_id = azurerm_network_security_group.my_project-nsg.id
}

# Randomm txt for unique storage account name
resource "random_id" "random_name" {
  keepers = {
    #    Genarate a new ID only when a new resource group is defined
    resource_group = azurerm_resource_group.my_project.name
  }

  byte_length = 8
}

# Create storage account
resource "azurerm_storage_account" "myproject_storage" {
  name                     = "diag${random_id.random_name.hex}"
  resource_group_name      = azurerm_resource_group.my_project.name
  location                 = azurerm_resource_group.my_project.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = "k8s-cluster"
  }
}

# Create network interface

resource "azurerm_network_interface" "my_project-nic" {
  name                = local.nic_name
  location            = azurerm_resource_group.my_project.location
  resource_group_name = azurerm_resource_group.my_project.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.my_project-subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.my_project-publicip.id
  }
}

resource "azurerm_linux_virtual_machine" "k8s-control-plane" {
  name                  = local.vm_cp_name
  resource_group_name   = azurerm_resource_group.my_project.name
  location              = azurerm_resource_group.my_project.location
  size                  = local.vm_size_cp
  admin_username        = local.admin_username
  network_interface_ids = [azurerm_network_interface.my_project-nic.id]
  custom_data           = filebase64("install_ansible.sh")
  # delete_os_disk_on_termination = true
  # delete_data_disks_on_termination = true

  admin_ssh_key {
    username   = local.admin_username
    public_key = file(local.ssh_key_name)
    # public_key = tls_private_key.my_project-ssh.public_key_openssh
  }

  os_disk {
    name                 = "${local.os_disk_name}_${local.vm_cp_name}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  computer_name                   = local.vm_cp_name
  disable_password_authentication = true

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.myproject_storage.primary_blob_endpoint
  }

  tags = {
    environment = "k8s-cluster"
  }

  provisioner "file" {
    connection {
      host = self.public_ip_address
      user = self.admin_username
      type = "ssh"
      private_key = file("SSH_KEY_FILE_PATH")
      timeout = "4m"
      agent = false
    }
      source = "examples/ansible"
      destination = "/home/${local.admin_username}/ansible"
  }

    provisioner "remote-exec" {
    connection {
      host = self.public_ip_address
      user = self.admin_username
      type = "ssh"
      private_key = file("SSH_KEY_FILE_PATH")
      timeout = "4m"
      agent = false
    }
      inline = [
        "chmod 400 /home/${local.admin_username}/ansible/${local.ssh_private_key_name}"
      ]
   }
}

  